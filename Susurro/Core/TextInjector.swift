import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

final class TextInjector {
    func insert(text: String, mode: TextInsertionMode) {
        guard AXIsProcessTrusted() else {
            print("[TextInjector] Accessibility permission is unavailable")
            return
        }

        switch mode {
        case .simulateTyping:
            simulateTyping(text: text)
        case .pasteboard:
            pasteboardInsert(text: text)
        }
    }

    private func simulateTyping(text: String) {
        let utf16 = Array(text.utf16)
        var i = 0
        let source = CGEventSource(stateID: .hidSystemState)

        while i < utf16.count {
            let unit = utf16[i]
            var characters: [UniChar]

            if unit >= 0xD800 && unit <= 0xDBFF && i + 1 < utf16.count {
                characters = [unit, utf16[i + 1]]
                i += 2
            } else {
                characters = [unit]
                i += 1
            }

            let count = characters.count

            if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
                keyDown.keyboardSetUnicodeString(stringLength: count, unicodeString: &characters)
                keyDown.post(tap: .cghidEventTap)
            }
            if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                keyUp.keyboardSetUnicodeString(stringLength: count, unicodeString: &characters)
                keyUp.post(tap: .cghidEventTap)
            }
        }
    }

    private func pasteboardInsert(text: String) {
        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        let source = CGEventSource(stateID: .hidSystemState)
        let cmdV = CGKeyCode(9)

        if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: cmdV, keyDown: true) {
            keyDown.flags = .maskCommand
            keyDown.post(tap: .cghidEventTap)
        }
        if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: cmdV, keyDown: false) {
            keyUp.flags = .maskCommand
            keyUp.post(tap: .cghidEventTap)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            if let prev = previous {
                pasteboard.setString(prev, forType: .string)
            }
        }
    }
}
