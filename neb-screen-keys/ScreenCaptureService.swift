//
//  ScreenCaptureService.swift
//  neb-screen-keys
//

import Cocoa
import ScreenCaptureKit
import AVFoundation

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
            guard let display = content.displays.first else { return nil }

            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
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
            return ScreenFrame(image: image, appName: appName, windowTitle: windowTitle)
        } catch {
            Logger.shared.log("ScreenCaptureKit error: \(error)")
            return nil
        }
    }
}

@available(macOS 14.0, *)
private final class OneShotFrameGrabber: NSObject, SCStreamOutput {
    private var continuation: CheckedContinuation<CGImage, Error>?
    private var cgImage: CGImage?

    func firstFrame() async throws -> CGImage {
        if let cgImage { return cgImage }
        return try await withCheckedThrowingContinuation { cont in
            continuation = cont
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen,
              let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ciImage = CIImage(cvImageBuffer: imageBuffer)
        let context = CIContext()
        if let cg = context.createCGImage(ciImage, from: ciImage.extent) {
            cgImage = cg
            continuation?.resume(returning: cg)
            continuation = nil
        }
    }
}

