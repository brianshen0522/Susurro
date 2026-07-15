import AppKit
import ApplicationServices
@preconcurrency import CoreGraphics
import Foundation

@MainActor
protocol HotkeyManagerDelegate: AnyObject {
    func hotkeyDidTriggerStart()
    func hotkeyDidTriggerStop()
}

@MainActor
final class HotkeyManager {
    weak var delegate: HotkeyManagerDelegate?

    private var mode: HotkeyTriggerMode = .pressAndHold(key: .fn)
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private var pressStartTime: Date?

    var isMonitoring: Bool {
        guard let eventTap else { return false }
        return CGEvent.tapIsEnabled(tap: eventTap)
    }

    var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    func requestAccessibilityPermission() -> Bool {
        let options: CFDictionary = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func updateConfiguration(_ newMode: HotkeyTriggerMode) {
        let wasMonitoring = eventTap != nil
        if wasMonitoring { stopMonitoring() }
        mode = newMode
        if wasMonitoring { startMonitoring() }
    }

    @discardableResult
    func startMonitoring() -> Bool {
        if eventTap != nil {
            guard !isMonitoring else {
                print("[HotkeyManager] already monitoring")
                return true
            }
            // Recreate a port that TCC or the system disabled.
            stopMonitoring()
        }

        print("[HotkeyManager] hasAccessibility=\(hasAccessibilityPermission)")
        print("[HotkeyManager] mode=\(mode)")

        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)

        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { proxy, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let mgr = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                // This callback is delivered by the source installed on the
                // main run loop below.
                return MainActor.assumeIsolated {
                    mgr.handleEvent(proxy: proxy, type: type, event: event)
                }
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let tap else {
            print("[HotkeyManager] ❌ CGEvent.tapCreate returned nil — Accessibility permission likely denied")
            return false
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        print("[HotkeyManager] ✅ event tap created and enabled")
        return true
    }

    func stopMonitoring() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
        }
        eventTap = nil
        runLoopSource = nil
        pressStartTime = nil
    }

    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            let wasPressed = pressStartTime != nil
            pressStartTime = nil
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            if wasPressed {
                delegate?.hotkeyDidTriggerStop()
            }
            return Unmanaged.passUnretained(event)
        }

        if case .pressAndHold(let key) = mode {
            handlePressAndHold(type: type, event: event, key: key)
        }
        return Unmanaged.passUnretained(event)
    }

    private func handlePressAndHold(type: CGEventType, event: CGEvent, key: HotkeyKey) {
        guard type == .flagsChanged else { return }

        let flags = event.flags
        print("[HotkeyManager] flagsChanged: flags=\(flags.rawValue) maskSecondaryFn=\(flags.contains(.maskSecondaryFn))")
        let isKeyDown = isKeyDown(flags: flags, key: key)

        if isKeyDown && pressStartTime == nil {
            pressStartTime = Date()
            // The event tap source is attached to the main run loop, so its
            // callback already executes on the UI thread.
            delegate?.hotkeyDidTriggerStart()
        } else if !isKeyDown && pressStartTime != nil {
            pressStartTime = nil
            delegate?.hotkeyDidTriggerStop()
        }
    }

    private func isKeyDown(flags: CGEventFlags, key: HotkeyKey) -> Bool {
        switch key {
        case .fn:
            return flags.contains(.maskSecondaryFn)
        case .rightCommand:
            return flags.contains(.maskCommand)
        case .rightOption:
            return flags.contains(.maskAlternate)
        case .f13:
            return false
        }
    }
}
