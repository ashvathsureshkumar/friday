//
//  ScreenCaptureService.swift
//  neb-screen-keys
//

import Cocoa
import ScreenCaptureKit
import AVFoundation
import CoreGraphics

final class ScreenCaptureService {
    private let captureQueue = DispatchQueue(label: "screen-capture.queue")

    func captureActiveScreen() async -> ScreenFrame? {
        guard #available(macOS 14.0, *) else { return nil }
        return await captureWithScreenCaptureKit()
    }

    @available(macOS 14.0, *)
    private func captureWithScreenCaptureKit() async -> ScreenFrame? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            
            // Find the active window (frontmost application's main window)
            if let activeWindow = findActiveWindow(from: content) {
                Logger.shared.log(.capture, "📸 Capturing active window: \(activeWindow.title ?? "Untitled") - \(activeWindow.owningApplication?.applicationName ?? "Unknown")")
                return await captureActiveWindow(activeWindow)
            }
            
            // Fallback: If no window found (e.g., our app is frontmost), capture main display
            Logger.shared.log(.capture, "No active window found, falling back to main display capture")
            guard let mainDisplay = content.displays.first else {
                Logger.shared.log(.capture, "No displays available")
                return nil
            }
            
            return await captureMainDisplay(mainDisplay, from: content)
        } catch {
            Logger.shared.log("ScreenCaptureKit error: \(error)")
            return nil
        }
    }
    
    /// Fallback: Capture main display when no active window is available
    @available(macOS 14.0, *)
    private func captureMainDisplay(_ display: SCDisplay, from content: SCShareableContent) async -> ScreenFrame? {
        do {
            // Get our app's bundle identifier to exclude it (avoid infinity mirror)
            let ourBundleID = Bundle.main.bundleIdentifier
            var excludedApps: [SCRunningApplication] = []
            
            if let bundleID = ourBundleID {
                if let ourApp = content.applications.first(where: { $0.bundleIdentifier == bundleID }) {
                    excludedApps.append(ourApp)
                    Logger.shared.log(.capture, "Excluding own app (\(bundleID)) from display capture")
                }
            }
            
            // Capture the entire main display
            let filter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.width = display.width
            config.height = display.height
            config.minimumFrameInterval = CMTimeMake(value: 1, timescale: 5)
            config.queueDepth = 1
            config.pixelFormat = kCVPixelFormatType_32BGRA

            let grabber = OneShotFrameGrabber()
            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            try stream.addStreamOutput(grabber, type: .screen, sampleHandlerQueue: captureQueue)

            try await stream.startCapture()
            let cgImage = try await grabber.firstFrame()
            try await stream.stopCapture()

            let image = NSImage(cgImage: cgImage, size: .zero)
            let frontApp = NSWorkspace.shared.frontmostApplication
            let appName = frontApp?.localizedName ?? "Unknown App"
            let windowTitle = frontApp?.localizedName ?? "Unknown Window"
            
            Logger.shared.log(.capture, "✓ Main display captured: \(display.width)x\(display.height)")
            return ScreenFrame(image: image, appName: appName, windowTitle: windowTitle)
        } catch {
            Logger.shared.log(.capture, "Failed to capture main display: \(error)")
            return nil
        }
    }
    
    /// Find the active window based on the frontmost application
    /// - Parameter content: Shareable content from ScreenCaptureKit
    /// - Returns: The active window, or nil if not found
    @available(macOS 14.0, *)
    private func findActiveWindow(from content: SCShareableContent) -> SCWindow? {
        // Get the frontmost application
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
            Logger.shared.log(.capture, "No frontmost application")
            return nil
        }
        
        let appName = frontmostApp.localizedName ?? "Unknown"
        let appPID = frontmostApp.processIdentifier
        let ourBundleID = Bundle.main.bundleIdentifier
        let ourPID = ProcessInfo.processInfo.processIdentifier
        
        Logger.shared.log(.capture, "Frontmost app: \(appName) (PID: \(appPID))")
        
        // Skip if our own app is frontmost (can't capture ourselves)
        if appPID == ourPID {
            Logger.shared.log(.capture, "⚠️ Our own app is frontmost, skipping capture (wait for user to switch apps)")
            return nil
        }
        
        // Also skip if bundle ID matches (double check)
        if let bundleID = ourBundleID, frontmostApp.bundleIdentifier == bundleID {
            Logger.shared.log(.capture, "⚠️ Our own app is frontmost (by bundle ID), skipping capture")
            return nil
        }
        
        // Get window info using CoreGraphics to find the active window
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            Logger.shared.log(.capture, "Failed to get window list")
            return nil
        }
        
        // Find the first window that belongs to the frontmost app
        // (First window in Z-order is the active one)
        for windowInfo in windowList {
            guard let windowPID = windowInfo[kCGWindowOwnerPID as String] as? pid_t,
                  windowPID == appPID,
                  let windowID = windowInfo[kCGWindowNumber as String] as? CGWindowID else {
                continue
            }
            
            // Skip tiny windows (likely UI elements, not main windows)
            if let boundsDict = windowInfo[kCGWindowBounds as String] as? [String: CGFloat],
               let width = boundsDict["Width"],
               let height = boundsDict["Height"],
               (width < 100 || height < 100) {
                continue
            }
            
            let windowTitle = windowInfo[kCGWindowName as String] as? String ?? "Untitled"
            Logger.shared.log(.capture, "Found active window: '\(windowTitle)' (ID: \(windowID))")
            
            // Match with ScreenCaptureKit window
            if let scWindow = content.windows.first(where: { $0.windowID == windowID }) {
                Logger.shared.log(.capture, "✅ Matched with ScreenCaptureKit window")
                return scWindow
            }
        }
        
        Logger.shared.log(.capture, "⚠️ No matching window found in ScreenCaptureKit")
        return nil
    }
    
    /// Capture only the active window (no dock, menu bar, or other windows)
    /// - Parameter window: The active window to capture
    /// - Returns: ScreenFrame with clean window capture
    @available(macOS 14.0, *)
    private func captureActiveWindow(_ window: SCWindow) async -> ScreenFrame? {
        do {
            // Use desktopIndependentWindow to capture ONLY this window
            // This excludes dock, menu bar, desktop, and all other windows
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            
            // Use window's actual dimensions
            config.width = Int(window.frame.width)
            config.height = Int(window.frame.height)
            config.minimumFrameInterval = CMTimeMake(value: 1, timescale: 5)
            config.queueDepth = 1
            config.pixelFormat = kCVPixelFormatType_32BGRA

            let grabber = OneShotFrameGrabber()
            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            try stream.addStreamOutput(grabber, type: .screen, sampleHandlerQueue: captureQueue)

            try await stream.startCapture()
            let cgImage = try await grabber.firstFrame()
            try await stream.stopCapture()

            let image = NSImage(cgImage: cgImage, size: .zero)
            let appName = window.owningApplication?.applicationName ?? "Unknown App"
            let windowTitle = window.title ?? "Untitled"
            
            Logger.shared.log(.capture, "✓ Active window captured: \(Int(window.frame.width))x\(Int(window.frame.height))")
            return ScreenFrame(image: image, appName: appName, windowTitle: windowTitle)
        } catch {
            Logger.shared.log(.capture, "Failed to capture window: \(error)")
            return nil
        }
    }
    
    /// Highlight cursor position with a red circle to guide AI attention
    /// - Parameter image: The captured screen CGImage
    /// - Returns: New CGImage with cursor indicator, or nil if drawing failed
    private func highlightCursorPosition(on image: CGImage) -> CGImage? {
        // Get current mouse cursor position
        guard let cursorEvent = CGEvent(source: nil),
              let cursorLocation = cursorEvent.location as CGPoint? else {
            Logger.shared.log(.capture, "Could not get cursor position")
            return nil
        }
        
        let width = image.width
        let height = image.height
        
        // Create drawing context
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            Logger.shared.log(.capture, "Failed to create CGContext for cursor highlight")
            return nil
        }
        
        // Draw original image
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        // Convert cursor coordinates (origin at top-left) to image coordinates (origin at bottom-left)
        let imageY = CGFloat(height) - cursorLocation.y
        
        // Draw red circle at cursor position
        let circleRadius: CGFloat = 40
        let strokeWidth: CGFloat = 4
        
        context.setStrokeColor(red: 1.0, green: 0.0, blue: 0.0, alpha: 0.9)
        context.setLineWidth(strokeWidth)
        
        let circleBounds = CGRect(
            x: cursorLocation.x - circleRadius,
            y: imageY - circleRadius,
            width: circleRadius * 2,
            height: circleRadius * 2
        )
        
        context.strokeEllipse(in: circleBounds)
        
        Logger.shared.log(.capture, "Cursor indicator drawn at (\(Int(cursorLocation.x)), \(Int(cursorLocation.y)))")
        
        // Return the new image with cursor highlight
        return context.makeImage()
    }
}

@available(macOS 14.0, *)
private final class OneShotFrameGrabber: NSObject, SCStreamOutput {
    private var continuation: CheckedContinuation<CGImage, Error>?
    
    func firstFrame() async throws -> CGImage {
        return try await withCheckedThrowingContinuation { cont in
            continuation = cont
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen,
              let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let continuation = continuation else { return }
        
        let ciImage = CIImage(cvImageBuffer: imageBuffer)
        let context = CIContext()
        if let cg = context.createCGImage(ciImage, from: ciImage.extent) {
            continuation.resume(returning: cg)
            self.continuation = nil
        }
    }
}