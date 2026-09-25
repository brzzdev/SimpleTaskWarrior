# The UI is AppKit

The app's UI is AppKit, and SwiftUI comes back only where it's the only option or there's an incredibly compelling reason. [The Replica path overruns the inspector](https://github.com/brzzdev/SimpleTaskWarrior/issues/55) showed where SwiftUI stops. Toolbar items only ever get their ideal width, macOS has no title placement, and `.navigationDocument` brings a proxy icon whose folder menu doesn't suit a task app. So no SwiftUI title can both truncate and grow with the window. An AppKit shell does it with no custom code: `NSSplitViewController` with sidebar, content and inspector items, plus an `NSToolbar` with tracking separators, lets the native `NSWindow` subtitle tail-truncate and always stop short of the inspector. The UI was about a thousand lines when we decided, all of it outside the Taskwarrior logic, so moving it cost little. [Move the UI to AppKit](https://github.com/brzzdev/SimpleTaskWarrior/issues/63) tracks the move. Hosting SwiftUI content inside AppKit containers would keep the same sizing fight at every boundary.

## Consequences

- Each Replica gets a plain `NSWindowController`, not an `NSDocument`. A Replica is a folder the app works in, not a file it saves. The app restores windows through `NSWindowRestoration` with the Replica's bookmark, and it keeps Open Recent through `NSDocumentController`'s recents API.
- A Replica shows in at most one window. Opening it again brings that window forward.
- The logic stays in TCA. View controllers bind to their store with swift-navigation's `observe`, and they present panels and alerts from store state. Menu commands reach the front window through the responder chain.
- AppKit's autosave owns view layout, keyed per Replica. That covers column widths, order, visibility and sort, plus the inspector's split. The reducer still sorts rows, but it no longer persists any layout of its own.
- The menu bar is built in code. There's no nib or storyboard.

## Considered options

- **Stay in SwiftUI and work around it.** A capped-width toolbar title fits, but it can't grow with the window.
- **AppKit chrome only.** An AppKit window, table and toolbar, with SwiftUI inside them. This keeps SwiftUI layout inside AppKit containers, which is where #55 came from.
- **`NSDocument` per Replica.** It gives restoration and Open Recent for free, but it brings the proxy icon, edited state and autosave. All of those would have to be switched off for a folder that's never saved.
