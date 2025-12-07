//
//  SpaceMonitor.swift
//  neb-screen-keys
//

import Cocoa

/// Monitors virtual desktop (Spaces) changes and application switches
final class SpaceMonitor {
    private var observers: [NSObjectProtocol] = []
    var onChange: ((String) -> Void)?

    func start() {
        Logger.shared.log(.event, "SpaceMonitor starting...")

        let workspace = NSWorkspace.shared
        let notificationCenter = workspace.notificationCenter

        // Monitor virtual desktop (Spaces) changes
        let spaceObserver = notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: workspace,
            queue: .main
        ) { [weak self] _ in
            Logger.shared.log(.event, "Space changed detected")
            self?.onChange?("space_change")
        }
        observers.append(spaceObserver)

        // Monitor application activation changes
        let appObserver = notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: workspace,
            queue: .main
        ) { [weak self] notification in
            if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                let appName = app.localizedName ?? "Unknown"
                Logger.shared.log(.event, "App switch detected: \(appName)")
                self?.onChange?("app_switch")
            }
        }
        observers.append(appObserver)

        Logger.shared.log(.event, "SpaceMonitor active. Listening for space/app changes.")
    }

    func stop() {
        let notificationCenter = NSWorkspace.shared.notificationCenter
        observers.forEach { notificationCenter.removeObserver($0) }
        observers.removeAll()
        Logger.shared.log(.event, "SpaceMonitor stopped")
    }

    deinit {
        stop()
    }
}
