//
//  AppDelegate.swift
//  neb-screen-keys
//
//  Created by Ashvath Suresh Kumar on 12/6/25.
//

import Cocoa

@main
class AppDelegate: NSObject, NSApplicationDelegate {

    private var coordinator: AppCoordinator?

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        EnvLoader.shared.load()
        coordinator = AppCoordinator()
        coordinator?.start()
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        // Clean up if needed
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }
}

