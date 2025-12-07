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
    private static let accessibilityPromptKey = "AccessibilityPromptShown"
    
    static func ensure(completion: @escaping (_ screen: PermissionStatus, _ accessibility: PermissionStatus) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let screen = checkScreenRecording()
            let ax = checkAccessibility()
            DispatchQueue.main.async {
                completion(screen, ax)
            }
        }
    }
    
    /// Reset the accessibility prompt flag (useful for testing)
    static func resetPromptFlag() {
        UserDefaults.standard.removeObject(forKey: accessibilityPromptKey)
    }

    private static func checkScreenRecording() -> PermissionStatus {
        // Check if permission is already granted
        if CGPreflightScreenCaptureAccess() {
            return .granted
        }
        
        // Permission not granted - request it (this will show system prompt)
        let granted = CGRequestScreenCaptureAccess()
        return granted ? .granted : .denied
    }

    private static func checkAccessibility() -> PermissionStatus {
        // First check WITHOUT prompting
        let trustedWithoutPrompt = AXIsProcessTrusted()
        if trustedWithoutPrompt {
            return .granted
        }
        
        // Not trusted yet - check if we should prompt
        // Only prompt on first check, then just return status
        let shouldPrompt = !UserDefaults.standard.bool(forKey: accessibilityPromptKey)
        
        if shouldPrompt {
            // Prompt user (only first time)
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            let trusted = AXIsProcessTrustedWithOptions(options)
            UserDefaults.standard.set(true, forKey: accessibilityPromptKey)
            return trusted ? .granted : .denied
        } else {
            // Just check status without prompting
            return AXIsProcessTrusted() ? .granted : .denied
        }
    }
}

