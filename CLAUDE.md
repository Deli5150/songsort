# SongSort (native macOS)

SwiftUI port of the Glaze app at `~/Glaze/SongSort/sources` (React + youtubei.js). Tinder-style
sorter for YouTube Music: swipe through Liked Songs (or any playlist), right = add to playlists,
left = skip. YouTube access is deliberately **unofficial**: no Data API, no OAuth. Sign-in is the
real Google page in a WKWebView; its cookies drive raw InnerTube (`music.youtube.com/youtubei/v1/*`,
client `WEB_REMIX`) calls with a SAPISIDHASH header. Sibling project: `~/YTCurator` (same layers).

## Build / run / release
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build` / `swift test`
- `scripts/bundle.sh [--install]` → `build/SongSort.app` (ad-hoc signed), optionally copied to `/Applications`.
- Swift 5 language mode + `BareSlashRegexLiterals`; macOS 26+ (Liquid Glass APIs).
- Version lives in `VERSION`. Release: add `## <v>` to CHANGELOG.md, commit, `scripts/release.sh <v>`
  (public repo Deli5150/songsort; asset `SongSort-<v>.dmg`).
- `App/Updater.swift`: checks GitHub Releases, verifies the DMG's sha256 digest, mounts it, swaps the
  .app, relaunches. End-to-end test without UI: copy the app somewhere, set its
  CFBundleShortVersionString lower, re-sign ad-hoc, run its binary with `SONGSORT_AUTO_INSTALL_UPDATE=1`.

## Layout
- `YouTube/InnerTube.swift` — transport + adaptive `RequestGate` (priority lane for user actions).
- `YouTube/MusicClient.swift` — every endpoint + caches (songs per playlist, library playlists,
  per-playlist membership `videoId → setVideoId`). `YouTube/Parsers.swift` — the only code that knows
  response shapes. If YouTube changes shapes, only these two files should change.
- `YouTube/YouTubeSession.swift` — WKWebView Google sign-in; its `dataStore` is shared with the player.
- `Player/PreviewPlayer.swift` — previews play through YouTube Music's own web player in a hidden,
  offscreen WKWebView (`movie_player.loadVideoById`, polled every 250ms, stopped at 30s). Chosen
  because stream URLs are ciphered for web clients and the cipher-free mobile clients (ANDROID_VR,
  IOS) get "confirm you're not a bot" after a few calls and their URLs 403 off-UA (tested 2026-11-13).
- `Store/ProgressStore.swift` — sorted ids per source playlist (`progress.json`); imports Glaze's
  WebKit localStorage (`playlistsort:sorted:<id>`, UTF-16LE values) on first launch.
- `Features/` — `AppModel` (all state/actions), `DeckView` (deck, card, action bar, sort options,
  ←/→/Space via an NSEvent monitor), `Sheets` (add-to-playlist multi-select, source picker).

Data: `~/Library/Application Support/SongSort/` (progress.json, diagnostics.log). Cache:
`~/Library/Caches/com.delvison.songsort/`. `log show` is useless for this app — read diagnostics.log.

## InnerTube notes (WEB_REMIX)
- Playlist songs: `browse` `VL<id>` (`VLLM` = Liked Songs) → `musicPlaylistShelfRenderer.contents`
  of `musicResponsiveListItemRenderer`; continuation token in a trailing `continuationItemRenderer`,
  next pages via `browse {continuation}` → `onResponseReceivedActions[].appendContinuationItemsAction`.
  Owned playlists also have a Suggestions shelf — ignore anything outside the playlist shelf.
- Library playlists: `browse FEmusic_liked_playlists` → `musicTwoRowItemRenderer` tiles (skip VLLM,
  VLSE, and the "New playlist" tile with no browseId).
- Add: `browse/edit_playlist` ACTION_ADD_VIDEO (+ DEDUPE_OPTION_SKIP). Remove needs the entry's
  `setVideoId` (`playlistItemData.playlistSetVideoId`). Create: `playlist/create` (PRIVATE).
- Fixtures in `Tests/SongSortTests/Fixtures` are real unauthenticated responses for a public
  playlist; scrub any IPs/personal data from new fixtures before committing.
