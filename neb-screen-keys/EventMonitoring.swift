//
//  EventMonitoring.swift
//  neb-screen-keys
//

import Cocoa

final class EventMonitor {
    private var monitors: [Any] = []
    var onShortcut: ((String) -> Void)?

    func start() {
        Logger.shared.log(.event, "EventMonitor starting...")
        let mask: NSEvent.EventTypeMask = [.keyDown, .flagsChanged]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handle(event:)) {
            monitors.append(monitor)
            Logger.shared.log(.event, "EventMonitor active. Listening for shortcuts.")
        }
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
    }

    private func handle(event: NSEvent) {
        if event.type == .keyDown {
            if event.modifierFlags.contains(.command) && event.keyCode == 48 {
                Logger.shared.log(.event, "Shortcut detected: Cmd+Tab (keyCode=48)")
                onShortcut?("cmd-tab")
            } else if event.modifierFlags.contains(.command) && event.keyCode == 49 {
                Logger.shared.log(.event, "Shortcut detected: Cmd+Space (keyCode=49)")
                onShortcut?("cmd-space")
            }
        }
    }
}

final class KeystrokeMonitor {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    var onKeyEvent: (() -> Void)?

    func start() {
        Logger.shared.log(.event, "KeystrokeMonitor starting...")
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        if let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                       place: .headInsertEventTap,
                                       options: .defaultTap,
                                       eventsOfInterest: mask,
                                       callback: { _, type, event, refcon in
                                           if type == .keyDown, let refcon = refcon {
                                               let monitor = Unmanaged<KeystrokeMonitor>.fromOpaque(refcon).takeUnretainedValue()
                                               // Note: Logging every keystroke would be too verbose
                                               // Only logging on buffer append in ContextBufferService
                                               monitor.onKeyEvent?()
                                           }
                                           return Unmanaged.passUnretained(event)
                                       },
                                       userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())) {
            eventTap = tap
            runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            if let source = runLoopSource {
                CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
                CGEvent.tapEnable(tap: tap, enable: true)
                Logger.shared.log(.event, "KeystrokeMonitor active. CGEventTap enabled.")
            }
        } else {
            Logger.shared.log(.event, "⚠️ KeystrokeMonitor failed to create event tap (check Accessibility permissions)")
        }
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
    }
}

