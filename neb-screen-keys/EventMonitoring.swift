//
//  EventMonitoring.swift
//  neb-screen-keys
//

import Cocoa

final class EventMonitor {
    private var monitors: [Any] = []
    var onShortcut: ((String) -> Void)?

    func start() {
        let mask: NSEvent.EventTypeMask = [.keyDown, .flagsChanged]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handle(event:)) {
            monitors.append(monitor)
        }
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
    }

    private func handle(event: NSEvent) {
        if event.type == .keyDown {
            if event.modifierFlags.contains(.command) && event.keyCode == 48 {
                onShortcut?("cmd-tab")
            } else if event.modifierFlags.contains(.command) && event.keyCode == 49 {
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
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        if let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                       place: .headInsertEventTap,
                                       options: .defaultTap,
                                       eventsOfInterest: mask,
                                       callback: { _, type, event, refcon in
                                           if type == .keyDown, let refcon = refcon {
                                               let monitor = Unmanaged<KeystrokeMonitor>.fromOpaque(refcon).takeUnretainedValue()
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
            }
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

