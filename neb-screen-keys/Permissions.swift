//
//  Permissions.swift
//  neb-screen-keys
//

import Cocoa
import ApplicationServices

enum PermissionStatus {
    case granted
    case denied
}

final class Permissions {
    static func ensure(completion: @escaping (_ screen: PermissionStatus, _ accessibility: PermissionStatus) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let screen = requestScreenRecording()
            let ax = requestAccessibility()
            DispatchQueue.main.async {
                completion(screen, ax)
            }
        }
    }

    private static func requestScreenRecording() -> PermissionStatus {
        if CGPreflightScreenCaptureAccess() {
            return .granted
        }
        let granted = CGRequestScreenCaptureAccess()
        return granted ? .granted : .denied
    }

    private static func requestAccessibility() -> PermissionStatus {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        return trusted ? .granted : .denied
    }
}

