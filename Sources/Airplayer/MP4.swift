import Foundation

/// Minimal ISO-BMFF helpers: split ffmpeg's fragmented MP4 output into an init segment and
/// media fragments, re-time fragments, and derive RFC 6381 codec strings.
enum MP4 {
    struct Box {
        let type: String
        let range: Range<Int>      // whole box, header included
        let headerSize: Int
        var payload: Range<Int> { (range.lowerBound + headerSize)..<range.upperBound }
    }

    static func boxes(_ d: Data, in range: Range<Int>? = nil) -> [Box] {
        var result: [Box] = []
        let r = range ?? 0..<d.count
        var o = r.lowerBound
        while o + 8 <= r.upperBound {
            var size = Int(d.u32(o))
            var header = 8
            if size == 1, o + 16 <= r.upperBound { size = Int(d.u64(o + 8)); header = 16 }
            if size == 0 { size = r.upperBound - o }
            guard size >= header, o + size <= r.upperBound else { break }
            let type = String(decoding: d[(o + 4)..<(o + 8)], as: UTF8.self)
            result.append(Box(type: type, range: o..<(o + size), headerSize: header))
            o += size
        }
        return result
    }

    static func find(_ d: Data, _ path: [String], in range: Range<Int>? = nil) -> Box? {
        guard let first = path.first, let box = boxes(d, in: range).first(where: { $0.type == first }) else { return nil }
        if path.count == 1 { return box }
        var inner = box.payload
        if first == "stsd" { inner = (inner.lowerBound + 8)..<inner.upperBound }
        if ["avc1", "hvc1", "hev1", "dvh1", "dvhe"].contains(first) { inner = (inner.lowerBound + 78)..<inner.upperBound }
        return find(d, Array(path.dropFirst()), in: inner)
    }

    struct Fragment {
        let range: Range<Int>      // moof + following mdat
        let baseDecodeTime: UInt64
        var firstCompositionOffset: Int64 = 0
    }

    struct Parsed {
        let initSegment: Data
        let timescale: UInt32
        let fragments: [Fragment]
    }

    static func parse(_ d: Data) throws -> Parsed {
        let top = boxes(d)
        guard let moov = top.first(where: { $0.type == "moov" }) else { throw ToolError(message: "ffmpeg output has no moov") }
        var initData = Data()
        if let ftyp = top.first(where: { $0.type == "ftyp" }) { initData.append(d[ftyp.range]) }
        initData.append(d[moov.range])

        guard let mdhd = find(d, ["moov", "trak", "mdia", "mdhd"]) else { throw ToolError(message: "no mdhd") }
        let p = mdhd.payload.lowerBound
        let timescale = d[p] == 1 ? d.u32(p + 20) : d.u32(p + 12)

        var fragments: [Fragment] = []
        for (i, box) in top.enumerated() where box.type == "moof" {
            guard i + 1 < top.count, top[i + 1].type == "mdat",
                  let tfdt = find(d, ["moof", "traf", "tfdt"], in: box.range) else { continue }
            let q = tfdt.payload.lowerBound
            let base = d[q] == 1 ? d.u64(q + 4) : UInt64(d.u32(q + 4))
            fragments.append(Fragment(range: box.lowerBoundRange(to: top[i + 1]), baseDecodeTime: base,
                                      firstCompositionOffset: firstCompositionOffset(d, moof: box)))
        }
        return Parsed(initSegment: initData, timescale: timescale, fragments: fragments)
    }

    /// Composition time offset (pts - dts) of the first sample in a fragment, from its trun box.
    static func firstCompositionOffset(_ d: Data, moof: Box) -> Int64 {
        guard let trun = find(d, ["moof", "traf", "trun"], in: moof.range) else { return 0 }
        let p = trun.payload.lowerBound
        let version = d[p]
        let flags = d.u32(p) & 0xFFFFFF
        guard flags & 0x800 != 0, d.u32(p + 4) > 0 else { return 0 }
        var o = p + 8
        if flags & 0x1 != 0 { o += 4 }       // data offset
        if flags & 0x4 != 0 { o += 4 }       // first sample flags
        if flags & 0x100 != 0 { o += 4 }     // sample duration
        if flags & 0x200 != 0 { o += 4 }     // sample size
        if flags & 0x400 != 0 { o += 4 }     // sample flags
        let raw = d.u32(o)
        return version == 1 ? Int64(Int32(bitPattern: raw)) : Int64(raw)
    }

    /// Concatenates fragments, shifting their decode times so the first one starts at `startTime`
    /// (in track timescale units) and renumbering them with `sequenceBase`.
    static func retime(_ d: Data, fragments: [Fragment], startTime: UInt64, sequenceBase: UInt32) -> Data {
        guard let firstBase = fragments.first?.baseDecodeTime else { return Data() }
        var out = Data()
        for (i, f) in fragments.enumerated() {
            var chunk = Data(d[f.range])
            if let mfhd = find(chunk, ["moof", "mfhd"]) {
                chunk.setU32(mfhd.payload.lowerBound + 4, sequenceBase + UInt32(i))
            }
            if let tfdt = find(chunk, ["moof", "traf", "tfdt"]) {
                let q = tfdt.payload.lowerBound
                let value = startTime &+ (f.baseDecodeTime &- firstBase)
                if chunk[q] == 1 { chunk.setU64(q + 4, value) } else { chunk.setU32(q + 4, UInt32(truncatingIfNeeded: value)) }
            }
            out.append(chunk)
        }
        return out
    }

    // MARK: - Codec strings (RFC 6381)

    static func videoCodec(initSegment d: Data) -> (codec: String, supplemental: String?) {
        guard let stsd = find(d, ["moov", "trak", "mdia", "minf", "stbl", "stsd"]) else { return ("hvc1", nil) }
        let entry = boxes(d, in: (stsd.payload.lowerBound + 8)..<stsd.payload.upperBound).first
        let fourcc = entry?.type ?? "hvc1"
        let path = ["moov", "trak", "mdia", "minf", "stbl", "stsd", fourcc]

        var dv: String?
        var dvProfile = 0, dvCompat = 0
        if let dvcC = find(d, path + ["dvcC"]) ?? find(d, path + ["dvvC"]) {
            let p = dvcC.payload.lowerBound
            dvProfile = Int(d[p + 2] >> 1)
            dvCompat = Int(d[p + 4] >> 4)
            let level = Int(((d[p + 2] & 1) << 5) | (d[p + 3] >> 3))
            dv = String(format: "dvh1.%02d.%02d", dvProfile, level)
        }

        if let avcC = find(d, path + ["avcC"]) {
            let p = avcC.payload.lowerBound
            return (String(format: "avc1.%02X%02X%02X", d[p + 1], d[p + 2], d[p + 3]), nil)
        }
        guard let hvcC = find(d, path + ["hvcC"]) else { return (fourcc, nil) }
        let p = hvcC.payload.lowerBound
        let b1 = d[p + 1]
        let space = ["", "A", "B", "C"][Int(b1 >> 6)]
        let tier = (b1 & 0x20) != 0 ? "H" : "L"
        let profileIdc = Int(b1 & 0x1F)
        var compat = d.u32(p + 2)
        var reversed: UInt32 = 0
        for _ in 0..<32 { reversed = (reversed << 1) | (compat & 1); compat >>= 1 }
        let level = Int(d[p + 12])
        var constraints = (6..<12).map { d[p + $0] }
        while let last = constraints.last, last == 0 { constraints.removeLast() }
        var hevc = "\(space)\(profileIdc).\(String(reversed, radix: 16, uppercase: true)).\(tier)\(level)"
        for c in constraints { hevc += String(format: ".%02X", c) }

        if fourcc.hasPrefix("dv"), let dv { return (dv, nil) }            // profile 5: Dolby Vision only
        // Profile 8.1: HDR10 base layer, Dolby Vision advertised as a supplemental codec.
        let supplemental = (dvProfile == 8 && dvCompat == 1) ? dv.map { $0 + "/db1p" } : nil
        return ("hvc1.\(hevc)", supplemental)
    }
}

private extension MP4.Box {
    func lowerBoundRange(to next: MP4.Box) -> Range<Int> { range.lowerBound..<next.range.upperBound }
}

extension Data {
    func u32(_ o: Int) -> UInt32 {
        let i = startIndex + o
        return UInt32(self[i]) << 24 | UInt32(self[i + 1]) << 16 | UInt32(self[i + 2]) << 8 | UInt32(self[i + 3])
    }

    func u64(_ o: Int) -> UInt64 { UInt64(u32(o)) << 32 | UInt64(u32(o + 4)) }

    mutating func setU32(_ o: Int, _ v: UInt32) {
        let i = startIndex + o
        for k in 0..<4 { self[i + k] = UInt8(truncatingIfNeeded: v >> (24 - 8 * k)) }
    }

    mutating func setU64(_ o: Int, _ v: UInt64) {
        setU32(o, UInt32(truncatingIfNeeded: v >> 32))
        setU32(o + 4, UInt32(truncatingIfNeeded: v))
    }
}
