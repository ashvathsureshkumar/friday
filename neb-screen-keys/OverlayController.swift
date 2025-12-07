//
//  OverlayController.swift
//  neb-screen-keys
//

import Cocoa

final class OverlayController {
    private var panel: NSPanel?
    private var promptPanel: NSPanel?
    var onAccept: (() -> Void)?
    var onDecline: (() -> Void)?

    func showSuggestion(text: String) {
        if panel == nil {
            panel = makePanel()
        }
        if let panel = panel, let label = panel.contentView?.subviews.compactMap({ $0 as? NSTextField }).first {
            label.stringValue = text
            positionPanelNearCursor(panel: panel)
            panel.orderFrontRegardless()
        }
    }

    func showDecision(text: String) {
        if promptPanel == nil {
            promptPanel = makeDecisionPanel()
        }
        if let promptPanel = promptPanel,
           let label = promptPanel.contentView?.subviews.compactMap({ $0 as? NSTextField }).first {
            label.stringValue = text
            positionDecisionTopRight(panel: promptPanel)
            promptPanel.orderFrontRegardless()
        }
    }

    func hideAll() {
        panel?.orderOut(nil)
        promptPanel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 200, y: 200, width: 320, height: 80),
            styleMask: [.nonactivatingPanel, .hudWindow],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        
        // Multi-line wrapping label to show suggestions
        let label = NSTextField(wrappingLabelWithString: "Grok can help with this task")
        label.frame = NSRect(x: 12, y: 12, width: 296, height: 56)
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = NSColor.labelColor
        label.maximumNumberOfLines = 3
        label.lineBreakMode = .byWordWrapping
        panel.contentView?.addSubview(label)
        return panel
    }

    private func makeDecisionPanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 20, y: NSScreen.main?.frame.height ?? 800 - 80, width: 300, height: 110),
            styleMask: [.nonactivatingPanel, .hudWindow],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        
        // Multi-line wrapping label for task description
        let label = NSTextField(wrappingLabelWithString: "Execute this task?")
        label.frame = NSRect(x: 12, y: 60, width: 276, height: 38)
        label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        label.textColor = NSColor.labelColor
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byWordWrapping
        label.alignment = .center
        panel.contentView?.addSubview(label)

        let yes = NSButton(title: "Yes, Execute", target: self, action: #selector(handleYes))
        yes.frame = NSRect(x: 20, y: 18, width: 120, height: 32)
        yes.bezelStyle = .rounded
        panel.contentView?.addSubview(yes)

        let no = NSButton(title: "Not Now", target: self, action: #selector(handleNo))
        no.frame = NSRect(x: 160, y: 18, width: 120, height: 32)
        no.bezelStyle = .rounded
        panel.contentView?.addSubview(no)
        return panel
    }

    @objc private func handleYes() {
        onAccept?()
        hideAll()
    }

    @objc private func handleNo() {
        onDecline?()
        hideAll()
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

