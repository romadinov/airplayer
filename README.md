# Airplayer

A macOS app that streams local movies (MKV, AVI, MP4, MOV, …) to an AirPlay 2 TV in up to 4K HDR / Dolby Vision,
with every audio track and both embedded and external text subtitles available.

## How it works
The app runs a small HTTP server on the LAN and presents the movie as an HLS stream:

- **Video**: HEVC/H.264 is stream-copied (no re-encode). Each ~6 s segment is cut on demand by ffmpeg straight
  from the source file, and its fMP4 timestamps are rewritten to match the source exactly, so seeking is instant.
  Other codecs (Xvid, MPEG-2, VC-1, …) are re-encoded per segment with VideoToolbox H.264.
- **Audio**: each track is a separate HLS audio rendition. AC-3 / E-AC-3 (incl. Atmos) / AAC are copied;
  DTS, TrueHD, FLAC, MP3, Opus… are transcoded to E-AC-3 5.1 or AAC stereo.
- **Subtitles**: embedded text subtitles and external `.srt/.ass/.ssa/.vtt` files (auto-detected next to the movie,
  or added with ⇧⌘O / drag-and-drop) become WebVTT renditions. Windows-1251 / KOI8-R files are detected.
  Bitmap subtitles (PGS, VobSub) are not supported.

AVPlayer plays the stream; picking the TV in the AirPlay menu hands the stream to the TV, which then pulls
segments from the Mac directly.

## Requirements
- macOS 14+, `brew install ffmpeg`
- The Mac and the TV on the same network (VPN tunnels are skipped when choosing the address to serve on)

## Build & run
```
./scripts/build-app.sh
open build/Airplayer.app
```
`Airplayer --serve <file>` runs only the HLS server and prints the master playlist URL (for testing with other players).

## License
MIT — see [LICENSE](LICENSE).
