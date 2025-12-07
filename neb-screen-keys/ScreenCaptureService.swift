//
//  ScreenCaptureService.swift
//  neb-screen-keys
//

import Cocoa

final class ScreenCaptureService {
    func captureActiveScreen() -> ScreenFrame? {
        let bounds = NSScreen.main?.frame ?? .zero
        guard let cgImage = CGWindowListCreateImage(bounds, .optionOnScreenOnly, kCGNullWindowID, .bestResolution) else { return nil }
        let image = NSImage(cgImage: cgImage, size: .zero)

        let frontApp = NSWorkspace.shared.frontmostApplication
        let appName = frontApp?.localizedName ?? "Unknown App"
        let windowTitle = frontApp?.localizedName ?? "Unknown Window"

        return ScreenFrame(image: image, appName: appName, windowTitle: windowTitle)
    }
}

