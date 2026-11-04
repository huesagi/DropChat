//
//  DropChatHarness.swift
//  DropChatHarness
//
//  The DroppyKit harness entry. Run it with `droppykit run`, or render every
//  surface without a window: `droppykit run -- --shots ./shots --report ./shots/report.json`.
//
//  Not named main.swift: Swift treats that name as top-level code, which
//  cannot coexist with @main.
//

import DropChat
import DroppyKit
import DroppyKitHarness

@main
struct DropChatHarness: DropletHarnessApp {
    static func makeDroplet() -> any Droplet { DropChatDroplet() }
}
