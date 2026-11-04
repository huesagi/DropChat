# DropChat, a Droplet for Droppy

DropChat is a Droplet (an extension that runs inside Droppy, the notch shelf for Mac) built with DroppyKit. It is an LLM chat on the shelf with an optional floating window.

- Droplet id `dropchat` (also `DropChatDroplet.id` and `id` in `droplet.json`; all three must agree).
- Swift product `DropChat` (dynamic library). Harness target `DropChatHarness`.
- SDK: https://gitlab.com/droppyformac1/droppykit (guides in `Sources/DroppyKit/Documentation.docc/`, API in `Sources/DroppyKit/`).

## Layout

- `Sources/DropChatCore`: Foundation-only engine. No DroppyKit, SwiftUI or AppKit imports. Everything here should be unit-testable; add tests in `Tests/DropChatCoreTests`.
- `Sources/DropChat`: the droplet (DroppyKit surfaces, SwiftUI views, AppKit panel). `AppModel` is the composition root.
- Only local targets: `droppykit build` links the droplet from this package's own modules, so a third-party Swift package would be missing from the shipped bundle.

## The loop

1. `swift test` (engine tests).
2. `droppykit build` writes `.build/DropChat.droplet`. Never ship a bare `swift build`.
3. `droppykit validate`.
4. `droppykit run -- --shots ./shots --report ./shots/report.json`; look at the PNGs; `problems` must be empty.
5. Install into Droppy Playground and confirm it loaded.

CI (`.github/workflows/build.yml`) runs all of this on macOS for every push.

## Rules that matter here

- `surfaces` in `droplet.json` (`shelf-widget`, `settings-pane`) match the protocol conformances. Add a surface in both places.
- Host calls are gated by `capabilities`; declare exactly what the code uses. `kit.minAPI` is the oldest DroppyKit API the code calls (`droppykit build` names the right one if it is too low).
- Everything `activate(host:)` starts, `deactivate()` stops: runs, MCP processes, the floating panel, the shortcut.
- Keep the main actor free: file I/O, AppleScript and processes run on their own queues (see `FileIO`, `ProcessRunner`, `FinderSelection`).
- Secrets go to the Keychain (`SecretStore`), never preferences. MCP env and headers are moved there by `SettingsRepository`.
- Anything that takes over, sends data or costs battery is off by default (floating window, Finder selection, web tools, skills, scripts).
- Look like Droppy: `AdaptiveColors`, `DroppySpacing`, `DroppyRadius`, Droppy button styles, no background or border on the widget root, sentence case.
- Never make or replace the droplet's icon (`DropChat.icon` is a placeholder; Droppy designs Store icons).
