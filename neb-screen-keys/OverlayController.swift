//
//  OverlayController.swift
//  neb-screen-keys
//

import Cocoa

final class OverlayController {
    private var panel: NSPanel?
    private var promptPanel: NSPanel?
    private var keyboardMonitor: Any?
    private var localKeyboardMonitor: Any?  // For when panel is focused
    private var mouseMonitor: Any?  // For cursor following
    private var clickOutsideMonitor: Any?  // For click-outside dismiss

    // Decision popup timer
    private var decisionTimer: Timer?
    private var decisionProgressFill: NSView?
    private let decisionTimeout: TimeInterval = 5.0

    // Cursor popup timer
    private var cursorTimer: Timer?
    private var cursorProgressFill: NSView?
    private let cursorTimeout: TimeInterval = 3.0

    var onAccept: (() -> Void)?
    var onDecline: (() -> Void)?

    // Nebula colors (matching ChatOverlayController)
    private let accentColor = NSColor(red: 0x1d/255.0, green: 0x10/255.0, blue: 0xb3/255.0, alpha: 1.0)
    private let spaceBackground = NSColor(red: 0x07/255.0, green: 0x0B/255.0, blue: 0x20/255.0, alpha: 0.85)
    private let glowBorderWidth: CGFloat = 2

    func showSuggestion(text: String, enableKeyboardShortcuts: Bool = false) {
        if panel == nil {
            panel = makePanel()
        }
        if let panel = panel, let label = panel.contentView?.viewWithTag(100) as? NSTextField {
            label.stringValue = text
            positionPanelNearCursor(panel: panel)
            panel.orderFrontRegardless()
            startMouseMonitor()
            startCursorTimer()

            // Enable keyboard shortcuts for cursor-style popups (⌘Y to accept, ⌘N to dismiss)
            if enableKeyboardShortcuts {
                startKeyboardMonitor()
            }
        }
    }

    func hideSuggestion() {
        stopMouseMonitor()
        stopCursorTimer()
        panel?.orderOut(nil)
    }

    func showDecision(text: String) {
        if promptPanel == nil {
            promptPanel = makeDecisionPanel()
        }
        if let promptPanel = promptPanel,
           let label = promptPanel.contentView?.viewWithTag(100) as? NSTextField {
            label.stringValue = text
            positionDecisionTopRight(panel: promptPanel)
            promptPanel.orderFrontRegardless()

            // Focus the panel so keyboard shortcuts work immediately
            promptPanel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)

            startKeyboardMonitor()
            startClickOutsideMonitor()
            startDecisionTimer()
        }
    }

    func hideDecision() {
        stopKeyboardMonitor()
        stopClickOutsideMonitor()
        stopDecisionTimer()
        promptPanel?.orderOut(nil)
    }

    func hideAll() {
        hideSuggestion()
        hideDecision()
    }

    private func startDecisionTimer() {
        stopDecisionTimer()

        // Reset progress bar
        decisionProgressFill?.frame.size.width = 0

        let panelWidth: CGFloat = 280
        let progressBarWidth = panelWidth - glowBorderWidth * 2 - 32
        let interval: TimeInterval = 0.03
        let steps = decisionTimeout / interval
        let progressStep = progressBarWidth / CGFloat(steps)
        var currentProgress: CGFloat = 0

        decisionTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }

            currentProgress += progressStep
            self.decisionProgressFill?.frame.size.width = currentProgress

            if currentProgress >= progressBarWidth {
                timer.invalidate()
                self.hideDecision() // Auto-dismiss only decision popup
                self.onDecline?()
            }
        }
    }

    private func stopDecisionTimer() {
        decisionTimer?.invalidate()
        decisionTimer = nil
        decisionProgressFill?.frame.size.width = 0
    }

    private func startCursorTimer() {
        stopCursorTimer()

        // Reset progress bar
        cursorProgressFill?.frame.size.width = 0

        let panelWidth: CGFloat = 280
        let progressBarWidth = panelWidth - glowBorderWidth * 2 - 32
        let interval: TimeInterval = 0.03
        let steps = cursorTimeout / interval
        let progressStep = progressBarWidth / CGFloat(steps)
        var currentProgress: CGFloat = 0

        cursorTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }

            currentProgress += progressStep
            self.cursorProgressFill?.frame.size.width = currentProgress

            if currentProgress >= progressBarWidth {
                timer.invalidate()
                self.hideSuggestion() // Auto-dismiss cursor popup
                self.onDecline?()    // Clear state so task can be re-offered
            }
        }
    }

    private func stopCursorTimer() {
        cursorTimer?.invalidate()
        cursorTimer = nil
        cursorProgressFill?.frame.size.width = 0
    }

    private func startKeyboardMonitor() {
        stopKeyboardMonitor()

        // Check if either panel is visible
        let isAnyPanelVisible: () -> Bool = { [weak self] in
            guard let self = self else { return false }
            return (self.promptPanel?.isVisible == true) || (self.panel?.isVisible == true)
        }

        // Handler for keyboard events
        let handleKeyEvent: (NSEvent) -> NSEvent? = { [weak self] event in
            guard let self = self, isAnyPanelVisible() else { return event }

            // Check for Command modifier
            let hasCommand = event.modifierFlags.contains(.command)
            guard hasCommand else { return event }

            if let chars = event.characters?.lowercased() {
                if chars == "y" {
                    DispatchQueue.main.async {
                        self.handleYes()
                    }
                    return nil  // Consume the event
                } else if chars == "n" {
                    DispatchQueue.main.async {
                        self.handleNo()
                    }
                    return nil  // Consume the event
                }
            }
            return event
        }

        // Global monitor for when other apps are focused
        keyboardMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, isAnyPanelVisible() else { return }

            let hasCommand = event.modifierFlags.contains(.command)
            guard hasCommand else { return }

            if let chars = event.characters?.lowercased() {
                if chars == "y" {
                    DispatchQueue.main.async {
                        self.handleYes()
                    }
                } else if chars == "n" {
                    DispatchQueue.main.async {
                        self.handleNo()
                    }
                }
            }
        }

        // Local monitor for when our panel is focused
        localKeyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: handleKeyEvent)
    }

    private func stopKeyboardMonitor() {
        if let monitor = keyboardMonitor {
            NSEvent.removeMonitor(monitor)
            keyboardMonitor = nil
        }
        if let monitor = localKeyboardMonitor {
            NSEvent.removeMonitor(monitor)
            localKeyboardMonitor = nil
        }
    }

    private func startMouseMonitor() {
        stopMouseMonitor()

        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            guard let self = self, let panel = self.panel, panel.isVisible else { return }
            DispatchQueue.main.async {
                self.positionPanelNearCursor(panel: panel)
            }
        }
    }

    private func stopMouseMonitor() {
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMonitor = nil
        }
    }

    private func startClickOutsideMonitor() {
        stopClickOutsideMonitor()

        // Monitor for clicks outside the decision panel
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self = self,
                  let panel = self.promptPanel,
                  panel.isVisible else { return }

            // Check if click is outside the panel
            let clickLocation = event.locationInWindow
            let screenLocation = NSEvent.mouseLocation

            // Get panel frame in screen coordinates
            let panelFrame = panel.frame

            if !panelFrame.contains(screenLocation) {
                // Click was outside the panel - just defocus, don't dismiss
                // The timer will handle auto-dismiss, or user can click back
                DispatchQueue.main.async {
                    panel.orderBack(nil)
                }
            }
        }
    }

    private func stopClickOutsideMonitor() {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
    }

    private func makePanel() -> NSPanel {
        let panelWidth: CGFloat = 280
        let panelHeight: CGFloat = 52

        let panel = NSPanel(
            contentRect: NSRect(x: 200, y: 200, width: panelWidth, height: panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.hasShadow = true

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight))
        contentView.wantsLayer = true
        contentView.layer?.masksToBounds = false
        panel.contentView = contentView

        // Subtle outer border (the gap effect)
        let outerBorder = NSView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight))
        outerBorder.wantsLayer = true
        outerBorder.layer?.cornerRadius = 14
        outerBorder.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        contentView.addSubview(outerBorder)

        // Blur background (inset to create gap)
        let blurView = NSVisualEffectView(frame: NSRect(x: glowBorderWidth, y: glowBorderWidth, width: panelWidth - glowBorderWidth * 2, height: panelHeight - glowBorderWidth * 2))
        blurView.blendingMode = .behindWindow
        blurView.material = .hudWindow
        blurView.state = .active
        blurView.wantsLayer = true
        blurView.layer?.cornerRadius = 12
        blurView.layer?.masksToBounds = true

        // Dark overlay
        let darkOverlay = NSView(frame: blurView.bounds)
        darkOverlay.autoresizingMask = [.width, .height]
        darkOverlay.wantsLayer = true
        darkOverlay.layer?.backgroundColor = spaceBackground.cgColor

        // Inner glow
        let innerGlow = CAGradientLayer()
        innerGlow.frame = darkOverlay.bounds
        innerGlow.type = .radial
        innerGlow.colors = [accentColor.withAlphaComponent(0.08).cgColor, NSColor.clear.cgColor]
        innerGlow.startPoint = CGPoint(x: 0.5, y: 0.5)
        innerGlow.endPoint = CGPoint(x: 1.0, y: 1.0)
        innerGlow.cornerRadius = 12
        darkOverlay.layer?.addSublayer(innerGlow)

        blurView.addSubview(darkOverlay)

        // Label
        let label = NSTextField(labelWithString: "")
        label.tag = 100
        label.frame = NSRect(x: 16, y: 18, width: panelWidth - glowBorderWidth * 2 - 32, height: 20)
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white.withAlphaComponent(0.9)
        label.backgroundColor = .clear
        label.lineBreakMode = .byTruncatingTail
        blurView.addSubview(label)

        // Progress bar at bottom
        let progressBarHeight: CGFloat = 3
        let progressBarInset: CGFloat = 16
        let progressBarWidth = panelWidth - glowBorderWidth * 2 - (progressBarInset * 2)

        let progressBar = NSView(frame: NSRect(x: progressBarInset, y: 8, width: progressBarWidth, height: progressBarHeight))
        progressBar.wantsLayer = true
        progressBar.layer?.cornerRadius = progressBarHeight / 2
        progressBar.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.1).cgColor
        blurView.addSubview(progressBar)

        let progressFill = NSView(frame: NSRect(x: 0, y: 0, width: 0, height: progressBarHeight))
        progressFill.wantsLayer = true
        progressFill.layer?.cornerRadius = progressBarHeight / 2
        progressFill.layer?.backgroundColor = accentColor.withAlphaComponent(0.7).cgColor
        progressBar.addSubview(progressFill)
        self.cursorProgressFill = progressFill

        contentView.addSubview(blurView)
        return panel
    }

    private func makeDecisionPanel() -> NSPanel {
        let panelWidth: CGFloat = 280
        let panelHeight: CGFloat = 94

        let panel = NSPanel(
            contentRect: NSRect(x: 20, y: NSScreen.main?.frame.height ?? 800 - 80, width: panelWidth, height: panelHeight),
            styleMask: [.borderless],  // Removed nonactivatingPanel to allow focus
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = false  // Allow panel to become key window

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight))
        contentView.wantsLayer = true
        contentView.layer?.masksToBounds = false
        panel.contentView = contentView

        // Subtle outer border (the gap effect)
        let outerBorder = NSView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight))
        outerBorder.wantsLayer = true
        outerBorder.layer?.cornerRadius = 16
        outerBorder.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        contentView.addSubview(outerBorder)

        // Blur background (inset to create gap)
        let blurView = NSVisualEffectView(frame: NSRect(x: glowBorderWidth, y: glowBorderWidth, width: panelWidth - glowBorderWidth * 2, height: panelHeight - glowBorderWidth * 2))
        blurView.blendingMode = .behindWindow
        blurView.material = .hudWindow
        blurView.state = .active
        blurView.wantsLayer = true
        blurView.layer?.cornerRadius = 14
        blurView.layer?.masksToBounds = true

        // Dark overlay
        let darkOverlay = NSView(frame: blurView.bounds)
        darkOverlay.autoresizingMask = [.width, .height]
        darkOverlay.wantsLayer = true
        darkOverlay.layer?.backgroundColor = spaceBackground.cgColor

        // Inner glow
        let innerGlow = CAGradientLayer()
        innerGlow.frame = darkOverlay.bounds
        innerGlow.type = .radial
        innerGlow.colors = [accentColor.withAlphaComponent(0.08).cgColor, NSColor.clear.cgColor]
        innerGlow.startPoint = CGPoint(x: 0.5, y: 0.5)
        innerGlow.endPoint = CGPoint(x: 1.0, y: 1.0)
        innerGlow.cornerRadius = 14
        darkOverlay.layer?.addSublayer(innerGlow)

        blurView.addSubview(darkOverlay)

        // Label
        let label = NSTextField(labelWithString: "")
        label.tag = 100
        label.frame = NSRect(x: 16, y: panelHeight - glowBorderWidth * 2 - 34, width: panelWidth - glowBorderWidth * 2 - 32, height: 20)
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white.withAlphaComponent(0.9)
        label.backgroundColor = .clear
        label.lineBreakMode = .byTruncatingTail
        blurView.addSubview(label)

        // Clickable buttons with keyboard shortcut hints
        let hintsContainer = NSView(frame: NSRect(x: 16, y: 20, width: panelWidth - glowBorderWidth * 2 - 32, height: 24))
        hintsContainer.wantsLayer = true

        // Accept button (⌘Y)
        let acceptButton = NSButton(frame: NSRect(x: 0, y: 0, width: 90, height: 24))
        acceptButton.title = ""
        acceptButton.bezelStyle = .inline
        acceptButton.isBordered = false
        acceptButton.wantsLayer = true
        acceptButton.layer?.cornerRadius = 6
        acceptButton.layer?.backgroundColor = accentColor.withAlphaComponent(0.5).cgColor
        acceptButton.target = self
        acceptButton.action = #selector(handleYes)

        // Create attributed string for button title
        let acceptTitle = NSMutableAttributedString()
        acceptTitle.append(NSAttributedString(string: "⌘Y ", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white
        ]))
        acceptTitle.append(NSAttributedString(string: "Accept", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.85)
        ]))
        acceptButton.attributedTitle = acceptTitle
        hintsContainer.addSubview(acceptButton)

        // Dismiss button (⌘N)
        let dismissButton = NSButton(frame: NSRect(x: hintsContainer.frame.width - 94, y: 0, width: 94, height: 24))
        dismissButton.title = ""
        dismissButton.bezelStyle = .inline
        dismissButton.isBordered = false
        dismissButton.wantsLayer = true
        dismissButton.layer?.cornerRadius = 6
        dismissButton.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.15).cgColor
        dismissButton.target = self
        dismissButton.action = #selector(handleNo)

        // Create attributed string for dismiss button
        let dismissTitle = NSMutableAttributedString()
        dismissTitle.append(NSAttributedString(string: "⌘N ", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.8)
        ]))
        dismissTitle.append(NSAttributedString(string: "Dismiss", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.7)
        ]))
        dismissButton.attributedTitle = dismissTitle
        hintsContainer.addSubview(dismissButton)

        blurView.addSubview(hintsContainer)

        // Progress bar at bottom
        let progressBarHeight: CGFloat = 3
        let progressBarInset: CGFloat = 16
        let progressBarWidth = panelWidth - glowBorderWidth * 2 - (progressBarInset * 2)

        let progressBar = NSView(frame: NSRect(x: progressBarInset, y: 10, width: progressBarWidth, height: progressBarHeight))
        progressBar.wantsLayer = true
        progressBar.layer?.cornerRadius = progressBarHeight / 2
        progressBar.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.1).cgColor
        blurView.addSubview(progressBar)

        let progressFill = NSView(frame: NSRect(x: 0, y: 0, width: 0, height: progressBarHeight))
        progressFill.wantsLayer = true
        progressFill.layer?.cornerRadius = progressBarHeight / 2
        progressFill.layer?.backgroundColor = accentColor.withAlphaComponent(0.7).cgColor
        progressBar.addSubview(progressFill)
        self.decisionProgressFill = progressFill

        contentView.addSubview(blurView)
        return panel
    }

    @objc private func handleYes() {
        hideAll()  // Hide both panels
        onAccept?()
    }

    @objc private func handleNo() {
        hideAll()  // Hide both panels
        onDecline?()
    }

    private func positionPanelNearCursor(panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        var frame = panel.frame
        frame.origin = NSPoint(x: mouse.x + 12, y: mouse.y - frame.height - 12)
        panel.setFrame(frame, display: false)
    }

    private func positionDecisionTopRight(panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        var frame = panel.frame
        let margin: CGFloat = 20
        frame.origin = NSPoint(x: screen.frame.width - frame.width - margin,
                               y: screen.frame.height - frame.height - margin)
        panel.setFrame(frame, display: false)
    }
}
