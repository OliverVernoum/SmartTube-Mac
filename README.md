# SmartTube for macOS

A native macOS (SwiftUI + AVPlayer) rebuild of [SmartTube](https://github.com/yuliskov/SmartTube), the ad-free
YouTube client for Android TV. It uses the same YouTube TV backend and logic as SmartTube's `MediaServiceCore`,
ported to Swift.

## Features

- **Ad-free playback** through the YouTube TV client, with the same stream-decoding approach as SmartTube
  (yt-dlp's ejs challenge solver, run in JavaScriptCore)
- Up to **8K / 60fps** with AV1 on Macs with hardware AV1 decoding (M3 or later); H.264 up to 1080p on other Macs.
  You can choose the codec and quality.
- **SponsorBlock**: a separate action for each category, segments marked on the seek bar, a skip button, a minimum
  segment length, a list of excluded channels and a jump-to-highlight button
- **Return YouTube Dislike** counts and **DeArrow** titles and thumbnails
- **Sign in with a TV code** (youtube.com/activate) with several accounts and brand accounts
- Sections for Home, Shorts, Subscriptions, Channels, History, Playlists, Music, Gaming, News, Sports, Movies, Live,
  Trending, Kids and Notifications
- **Channel groups** (combined feeds), with import from NewPipe, PocketTube and Grayjay
- Search with suggestions, search history and filters (date, type, duration, sort, Live, 4K, HD, CC)
- Channel pages with Videos, Shorts, Live, Playlists, Releases and Community tabs, plus search inside a channel
- Player features:
  - Chapters, and storyboard previews when you hover over the seek bar
  - Speed from 0.25x to 4x, remembered per channel or per video
  - Subtitles with auto-translate and style, size and position options
  - Multiple audio languages and an audio-only mode
  - Picture-in-picture, full screen and a mini-player
  - Live streams with live chat
  - Comments, including replies, sort options and likes
  - Up next, playlist queue and autoplay modes (repeat one or all, shuffle, pause after each video)
  - Sleep timer, plus zoom, rotate and mirror for the video
- Like, dislike, subscribe, notification bell, add to or remove from playlists, create, rename or delete
  playlists, "Not interested", and block a channel
- Watch history sync (watch time is reported like SmartTube does) and resume from the last position
- Hiding filters for Shorts (set separately for each section), upcoming videos and watched videos
- Settings backup and restore, plus an optional password on Settings
- Media keys and Now Playing integration, keyboard shortcuts, and `youtube.com` / `youtu.be` link handling

### Keyboard shortcuts (player)

| Key | Action |
| --- | --- |
| Space / K | Play / pause |
| ← / → (J / L) | Seek (Shift for 3×) |
| ↑ / ↓ | Volume |
| F | Full screen |
| M | Mute |
| C | Subtitles |
| Shift+N / Shift+P | Next / previous |
| < / > | Speed |
| S | Skip a SponsorBlock segment |
| 0–9 | Jump to 0–90 % |
| I / Esc | Minimize |

## Install

Download `SmartTube.dmg` from the latest GitHub Actions run (Artifacts) or Release, open it and drag
SmartTube into Applications.

The app is ad-hoc signed rather than notarized, so the first time you open it, right-click SmartTube.app, choose
**Open** and then **Open** again. You can also run:

```bash
xattr -cr /Applications/SmartTube.app
```

Requires macOS 14 Sonoma or later.

## Build from source

```bash
swift test
```

```bash
Packaging/build-app.sh
```

These run the tests and build `dist/SmartTube.app` and `dist/SmartTube.dmg`. They need Xcode 16 or later.
For development you can also open `Package.swift` in Xcode and run it.

## How playback works

1. The app reads `youtube.com/tv` to get the visitor data, the TV player script and the OAuth client used for TV
   code sign-in.
2. It sends a `player` request with the TV client, the same order of clients SmartTube tries.
3. The `n` (throttling) and signature challenges are solved by the bundled ejs solver
   (`Resources/nsigsolver`) in JavaScriptCore.
4. YouTube serves separate DASH audio and video streams, which AVPlayer can't combine directly. The app turns
   them into an in-memory HLS presentation (byte-range segments read from each stream's `sidx` index), which
   AVPlayer then plays natively.

## License

MIT. Based on SmartTube by yuliskov (MIT).
