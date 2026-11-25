# ClipShelf

An open-source, native macOS clipboard shelf built in Swift, AppKit, and SwiftUI.

## Features
- **Non-activating bottom shelf** (`⇧⌘V`) that slides up across Spaces and full-screen apps without stealing focus context.
- **Visual cards** with source-app color-tinted headers, app icons, relative timestamps, rich link previews (`LinkPresentation`), image thumbnails, file badges, and color swatches.
- **Expanding inline search** (`⌘F`) that collapses the `+` button and `"Clipboard"` label while keeping the history icon visible.
- **Color-coded Pinboards** (`+` button) to organize frequently used snippets, links, and assets.
- **Keyboard-first workflow**: `←`/`→` navigate, `↩` paste, `⇧↩` paste plain text, `⌘1`–`⌘9` instant paste, `Space` Quick Look preview, `⌘⌫` delete, `Esc` dismiss.
- **Privacy Rules**: Ignores confidential/transient pasteboard types and defaults to ignoring **Passwords** and **Keychain Access**.
- **Original tactile sound effects** with optional local override support.

## Build & Run
```bash
chmod +x scripts/build_app.sh
./scripts/build_app.sh
open build/ClipShelf.app
```

## Run Tests
```bash
swift test
```

## Custom Sound Overrides (Gitignored)
ClipShelf ships with original synthesized `Copy.aiff` and `Paste.aiff` sound effects. To use your own local sound files without tracking them in git, drop `Copy.aiff` and/or `Paste.aiff` into either:
- `~/Library/Application Support/ClipShelf/Sounds/` (takes effect immediately), or
- `LocalSounds/` in the repo root (gitignored, bundled when running `./scripts/build_app.sh`).
