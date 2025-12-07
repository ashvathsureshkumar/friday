//
//  ScreenCaptureService.swift
//  neb-screen-keys
//

import Cocoa
import ScreenCaptureKit
import CoreGraphics

final class ScreenCaptureService {
    
    func captureActiveScreen() async -> ScreenFrame? {
        Logger.shared.log(.capture, "🎬 captureActiveScreen() called")
        guard #available(macOS 14.0, *) else {
            Logger.shared.log(.capture, "❌ macOS version < 14.0, capture not available")
            return nil
        }
        
        return await captureMainDisplay()
    }
    
    @available(macOS 14.0, *)
    private func captureMainDisplay() async -> ScreenFrame? {
        var stream: SCStream?
        do {
            Logger.shared.log(.capture, "📡 Requesting SCShareableContent...")
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            
            guard let mainDisplay = content.displays.first else {
                Logger.shared.log(.capture, "No displays available")
                return nil
            }
            
            Logger.shared.log(.capture, "Capturing main display: \(mainDisplay.width)x\(mainDisplay.height)")
            
            // Get our app to exclude it
            let ourBundleID = Bundle.main.bundleIdentifier
            var excludedApps: [SCRunningApplication] = []
            if let bundleID = ourBundleID,
               let ourApp = content.applications.first(where: { $0.bundleIdentifier == bundleID }) {
                excludedApps.append(ourApp)
            }
            
            // Simple capture: just the main display
            let filter = SCContentFilter(display: mainDisplay, excludingApplications: excludedApps, exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.width = mainDisplay.width
            config.height = mainDisplay.height
            config.minimumFrameInterval = CMTimeMake(value: 1, timescale: 1)
            config.queueDepth = 1
            config.pixelFormat = kCVPixelFormatType_32BGRA
            
            let grabber = SimpleFrameGrabber()
            stream = SCStream(filter: filter, configuration: config, delegate: nil)
            try stream!.addStreamOutput(grabber, type: .screen, sampleHandlerQueue: DispatchQueue.global())
            
            Logger.shared.log(.capture, "Starting capture stream...")
            try await stream!.startCapture()
            
            // Wait for frame with 2 second timeout
            Logger.shared.log(.capture, "Waiting for frame (2s timeout)...")
            let cgImage = try await grabber.waitForFrame(timeoutSeconds: 2)
            
            Logger.shared.log(.capture, "Frame received, stopping stream...")
            try await stream!.stopCapture()
            stream = nil
            
            let image = NSImage(cgImage: cgImage, size: .zero)
            let frontApp = NSWorkspace.shared.frontmostApplication
            let appName = frontApp?.localizedName ?? "Unknown App"
            let windowTitle = frontApp?.localizedName ?? "Unknown Window"
            
            Logger.shared.log(.capture, "✓ Screenshot captured: \(mainDisplay.width)x\(mainDisplay.height)")
            
            return ScreenFrame(image: image, appName: appName, windowTitle: windowTitle)
        } catch {
            Logger.shared.log(.capture, "❌ Capture failed: \(error.localizedDescription)")
            // Always stop stream on error to prevent hanging
            if let stream = stream {
                Logger.shared.log(.capture, "Cleaning up stream after error...")
                try? await stream.stopCapture()
            }
            return nil
        }
    }
}

@available(macOS 14.0, *)
private final class SimpleFrameGrabber: NSObject, SCStreamOutput {
    private var continuation: CheckedContinuation<CGImage, Error>?
    private let lock = NSLock()
    
    func waitForFrame(timeoutSeconds: Int) async throws -> CGImage {
        return try await withThrowingTaskGroup(of: CGImage.self) { group in
            // Wait for frame
            group.addTask { [weak self] in
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<CGImage, Error>) in
                    self?.lock.lock()
                    self?.continuation = cont
                    self?.lock.unlock()
                }
            }
            
            // Timeout - always fires to prevent infinite wait
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds) * 1_000_000_000)
                // Clear continuation on timeout to prevent memory leak
                self.lock.lock()
                if let cont = self.continuation {
                    self.continuation = nil
                    self.lock.unlock()
                    cont.resume(throwing: NSError(domain: "ScreenCaptureService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Screenshot timeout after \(timeoutSeconds) seconds"]))
                } else {
                    self.lock.unlock()
                }
                throw NSError(domain: "ScreenCaptureService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Screenshot timeout after \(timeoutSeconds) seconds"])
            }
            
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
    
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen,
              let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        
        lock.lock()
        guard let continuation = continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()
        
        let ciImage = CIImage(cvImageBuffer: imageBuffer)
        let context = CIContext()
        if let cg = context.createCGImage(ciImage, from: ciImage.extent) {
            continuation.resume(returning: cg)
        } else {
            continuation.resume(throwing: NSError(domain: "ScreenCaptureService", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to convert image buffer"]))
        }
    }
}
