# SongSort

A native macOS app for organizing your YouTube Music library. Swipe through your Liked Songs (or
any playlist) one card at a time: right to file a song into one or more playlists, left to skip
it for now. Each card shows the cover art, which other playlists already hold the song, and plays
a 30-second preview.

YouTube Music access is unofficial: you sign in on the real Google page inside the app, and its
session cookies drive YouTube Music's internal web API (InnerTube). No API key or OAuth app is
involved, and nothing leaves your Mac except requests to YouTube and GitHub (update checks).

## Features

- **Card deck** — drag a card right to add, left to skip, or use ← / → and Space to play.
- **Multi-playlist add** — check several playlists and add the song to all of them at once;
  playlists that already contain it are marked. Create a new (private) playlist inline.
- **Sort any playlist** — switch the source from Liked Songs to any of your playlists (⌘O).
  Progress is kept per playlist; skipped songs come back next launch or with one click.
- **Move mode** — when sorting a regular playlist, remove the song from it as it's filed.
- **Hide already-filed** — on Liked Songs, hide songs that are already in another playlist.
- **Previews** — 30 seconds through YouTube Music's own web player, optionally auto-playing
  each new card.

## Install

1. Download `SongSort-<version>.dmg` from the [latest release](https://github.com/Deli5150/songsort/releases/latest) and open it.
2. Drag **SongSort** onto the **Applications** shortcut.
3. The app is ad-hoc signed, not notarized, so open it the first time with right-click → **Open**
   (or run `xattr -dr com.apple.quarantine /Applications/SongSort.app`).

Requires macOS 26 or later. After that, the app updates itself: **SongSort → Check for Updates…**,
and it checks automatically every few hours (Settings → Updates).

## Build from source

Needs Xcode 26+.

```sh
swift build                 # debug build
swift test                  # parser + logic tests
scripts/bundle.sh --install # release build → build/SongSort.app, copied to /Applications
```

## Releasing

Add a `## <version>` section to `CHANGELOG.md`, commit, then run `scripts/release.sh <version>`.
It bumps `VERSION`, builds a drag-to-install DMG, tags, pushes, and publishes the GitHub release
that the in-app updater reads.
