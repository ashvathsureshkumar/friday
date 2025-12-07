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
            contentRect: NSRect(x: 200, y: 200, width: 260, height: 56),
            styleMask: [.nonactivatingPanel, .hudWindow],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        let label = NSTextField(labelWithString: "Grok can help with this task")
        label.frame = NSRect(x: 12, y: 16, width: 216, height: 24)
        panel.contentView?.addSubview(label)
        return panel
    }

    private func makeDecisionPanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 20, y: NSScreen.main?.frame.height ?? 800 - 80, width: 260, height: 90),
            styleMask: [.nonactivatingPanel, .hudWindow],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        let label = NSTextField(labelWithString: "Execute this task?")
        label.frame = NSRect(x: 12, y: 50, width: 236, height: 24)
        panel.contentView?.addSubview(label)

        let yes = NSButton(title: "Yes", target: self, action: #selector(handleYes))
        yes.frame = NSRect(x: 20, y: 14, width: 80, height: 28)
        panel.contentView?.addSubview(yes)

        let no = NSButton(title: "No", target: self, action: #selector(handleNo))
        no.frame = NSRect(x: 160, y: 14, width: 80, height: 28)
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

