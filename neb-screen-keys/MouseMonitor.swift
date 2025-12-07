//
//  MouseMonitor.swift
//  neb-screen-keys
//

import Cocoa
import ApplicationServices

/// Monitors global mouse clicks with debouncing
final class MouseMonitor {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var lastClickTime: Date?
    private let debounceInterval: TimeInterval = 0.5 // 500ms debounce
    
    var onClick: (() -> Void)?

    func start() {
        Logger.shared.log(.event, "MouseMonitor starting...")
        
        // Check if Accessibility permissions are granted
        let checkOpt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as NSString
        let options = [checkOpt: false]
        let accessEnabled = AXIsProcessTrustedWithOptions(options as CFDictionary)
        
        if !accessEnabled {
            Logger.shared.log(.event, "⚠️ MouseMonitor: Accessibility permission not granted. Mouse clicks will not be detected.")
            Logger.shared.log(.event, "   Please grant Accessibility permission in System Settings → Privacy & Security → Accessibility")
        }
        
        let mask = CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
        
        if let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard type == .leftMouseDown,
                      let refcon = refcon else {
                    return Unmanaged.passUnretained(event)
                }
                
                let monitor = Unmanaged<MouseMonitor>.fromOpaque(refcon).takeUnretainedValue()
                
                // Debounce: ignore clicks within debounceInterval
                let now = Date()
                if let lastClick = monitor.lastClickTime,
                   now.timeIntervalSince(lastClick) < monitor.debounceInterval {
                    // Too soon, ignore
                    return Unmanaged.passUnretained(event)
                }
                
                monitor.lastClickTime = now
                Logger.shared.log(.event, "🖱️ Mouse click detected")
                // Dispatch to main thread to ensure UI updates happen correctly
                DispatchQueue.main.async {
                    monitor.onClick?()
                }
                
                return Unmanaged.passUnretained(event)
            },
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        ) {
            eventTap = tap
            runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            
            if let source = runLoopSource {
                CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
                CGEvent.tapEnable(tap: tap, enable: true)
                Logger.shared.log(.event, "✅ MouseMonitor active. CGEventTap enabled.")
            } else {
                Logger.shared.log(.event, "❌ MouseMonitor failed to create run loop source")
            }
        } else {
            Logger.shared.log(.event, "❌ MouseMonitor failed to create event tap (check Accessibility permissions)")
            Logger.shared.log(.event, "   Accessibility permission is required for mouse click monitoring")
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
        Logger.shared.log(.event, "MouseMonitor stopped")
    }

    deinit {
        stop()
    }
}
