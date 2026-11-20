import AppKit
import CoreGraphics

/// Pastes text at the cursor without clobbering the clipboard: deep-copy every pasteboard item
/// and type (not just .string), set our text, synthesize Cmd+V, then restore after a short
/// delay. The target app reads the pasteboard asynchronously after Cmd+V, so restoring
/// immediately would race and paste nothing — hence the ~150 ms wait.
enum Paster {
    /// Clipboard-only: put the text on the clipboard and leave it there for the user to paste when
    /// and where they want. No synthesized Cmd+V, no save/restore — so no surprise paste at the
    /// wrong cursor, and Accessibility isn't needed in this mode.
    static func copy(_ text: String) {
        guard !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// `restoreAfter` is the delay before putting the original clipboard back. There's no reliable
    /// signal that the target app has read the pasteboard, so this is a tuned wait (config
    /// `paste_restore_ms`); raise it for slow/busy apps that paste late.
    static func paste(_ text: String, restoreAfter: TimeInterval = 0.25) {
        guard !text.isEmpty else { return }
        let pb = NSPasteboard.general
        let saved = snapshot(pb)
        pb.clearContents()
        pb.setString(text, forType: .string)
        synthesizeCmdV()
        DispatchQueue.main.asyncAfter(deadline: .now() + restoreAfter) {
            pb.clearContents()
            if !saved.isEmpty { pb.writeObjects(saved) }
        }
    }

    /// Fresh NSPasteboardItem copies (the originals can't be re-written to a pasteboard).
    private static func snapshot(_ pb: NSPasteboard) -> [NSPasteboardItem] {
        (pb.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
    }

    private static func synthesizeCmdV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 0x09
        let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cgSessionEventTap)
        up?.post(tap: .cgSessionEventTap)
    }
}
