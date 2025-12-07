//
//  ChatOverlayController.swift
//  neb-screen-keys
//

import Cocoa

// MARK: - NSBezierPath Extension

extension NSBezierPath {
    var cgPath: CGPath {
        let path = CGMutablePath()
        var points = [CGPoint](repeating: .zero, count: 3)
        for i in 0..<elementCount {
            let type = element(at: i, associatedPoints: &points)
            switch type {
            case .moveTo:
                path.move(to: points[0])
            case .lineTo:
                path.addLine(to: points[0])
            case .curveTo:
                path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .closePath:
                path.closeSubpath()
            case .cubicCurveTo:
                path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .quadraticCurveTo:
                path.addQuadCurve(to: points[1], control: points[0])
            @unknown default:
                break
            }
        }
        return path
    }
}

struct ChatMessage {
    let role: String
    let content: String
}

struct ThinkingShimmerFactory {
    struct Components {
        let gradient: CAGradientLayer
        let mask: CATextLayer
        let animation: CABasicAnimation
    }

    static func make(
        bounds: CGRect,
        text: String,
        font: NSFont,
        baseColor: NSColor,
        highlightColor: NSColor,
        baseAlpha: CGFloat = 0.25,
        highlightAlpha: CGFloat = 1.0,
        duration: CFTimeInterval = 0.8
    ) -> Components {
        let gradient = CAGradientLayer()
        gradient.frame = bounds
        gradient.colors = [
            baseColor.withAlphaComponent(baseAlpha).cgColor,
            highlightColor.withAlphaComponent(highlightAlpha).cgColor,
            baseColor.withAlphaComponent(baseAlpha).cgColor
        ]
        gradient.locations = [
            NSNumber(value: -0.4),
            NSNumber(value: -0.2),
            NSNumber(value: 0.0)
        ]
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)

        let mask = CATextLayer()
        mask.frame = bounds
        mask.string = text
        mask.font = font
        mask.fontSize = font.pointSize
        mask.alignmentMode = .left
        mask.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        mask.isWrapped = true
        // Mask is returned to caller; not applied here so callers can reuse a separate mask for base fill.

        let animation = CABasicAnimation(keyPath: "locations")
        animation.fromValue = [
            NSNumber(value: -0.4),
            NSNumber(value: -0.2),
            NSNumber(value: 0.0)
        ]
        animation.toValue = [
            NSNumber(value: 1.0),
            NSNumber(value: 1.2),
            NSNumber(value: 1.4)
        ]
        animation.duration = duration
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.isRemovedOnCompletion = false

        return Components(gradient: gradient, mask: mask, animation: animation)
    }
}

// Custom cell that vertically centers single-line text (placeholder) but aligns multiline to top
class VerticallyCenteredTextFieldCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        let newRect = super.drawingRect(forBounds: rect)
        let textSize = cellSize(forBounds: rect)
        let heightDelta = newRect.height - textSize.height

        // Only center if it's a single line (placeholder or short text)
        let isSingleLine = textSize.height < 30 // Approximate single line height
        if heightDelta > 0 && isSingleLine {
            return NSRect(x: newRect.origin.x, y: newRect.origin.y + heightDelta / 2, width: newRect.width, height: textSize.height)
        }
        return newRect
    }
}

final class ChatOverlayController: NSObject {
    private var panel: NSPanel?
    private var scrollView: NSScrollView?
    private var messagesContainer: NSStackView?
    private var messagesBlurView: NSVisualEffectView?
    private var inputField: NSTextField?
    private var inputContainer: NSView?
    private var messages: [ChatMessage] = []
    private var responseLabel: NSTextField?  // Simple text label for latest response
    private var responseScrollView: NSScrollView?  // Scroll view for long responses

    // State
    private var inactivityTimer: Timer?
    private let inactivityTimeout: TimeInterval = 10.0
    private var globalKeyboardMonitor: Any?
    private var localKeyboardMonitor: Any?
    private var inputText: String = ""
    private var inputBlurView: NSVisualEffectView?
    private var glowAnimation: CABasicAnimation?
    private var messagesBorderView: NSView?  // Suspended border for messages area only
    private var shimmerLayer: CAGradientLayer?
    private var shimmerAnimation: CABasicAnimation?

    // Nebula colors
    private let accentColor = NSColor(red: 0x1d/255.0, green: 0x10/255.0, blue: 0xb3/255.0, alpha: 1.0)
    private let spaceBackground = NSColor(red: 0x07/255.0, green: 0x0B/255.0, blue: 0x20/255.0, alpha: 0.85)
    private let glassBorder = NSColor.white.withAlphaComponent(0.1)
    private let messageUserBg = NSColor(red: 0x1d/255.0, green: 0x10/255.0, blue: 0xb3/255.0, alpha: 0.4)
    private let messageAssistantBg = NSColor.white.withAlphaComponent(0.08)
    private let responseTextColor = NSColor.white.withAlphaComponent(0.95)
    private let thinkingBaseFillColor = NSColor.white.withAlphaComponent(0.45)          // Gray base fill
    private let thinkingGradientBaseColor = NSColor.white.withAlphaComponent(0.25)      // Subtle gray streak base
    private let thinkingGradientHighlightColor = NSColor.white.withAlphaComponent(0.95) // Bright white streak
    private let thinkingBaseTextColor = NSColor.white.withAlphaComponent(0.6)           // Visible gray text when idle
    private var shimmerBaseLayer: CALayer?

    // Dimensions
    private let baseInputAreaHeight: CGFloat = 54  // Base input box height (one line)
    private let panelWidth: CGFloat = 384
    private let glowBorderWidth: CGFloat = 2  // Gap for spinning glow and suspended border
    private let baseInputFieldHeight: CGFloat = 32  // Single line input
    private let maxInputFieldHeight: CGFloat = 120  // Max input height before scrolling
    private let maxMessagesHeight: CGFloat = 400  // Max height before scrolling
    private let messageSpacing: CGFloat = 8  // Gap between input and messages
    private var currentInputHeight: CGFloat = 32  // Current dynamic input height

    var onSendMessage: ((String) -> Void)?
    var onExecuteScript: (() -> Void)?
    var onCancelScript: (() -> Void)?
    var onChatOpened: (() -> Void)?  // Called when chat is shown

    private var scriptPending = false
    private var inputEnabled = false  // Input hidden until greeting shown
    private var waitingForResponse = false  // Pause inactivity timer while waiting

    private var isVisible: Bool {
        panel?.isVisible ?? false
    }

    private var currentInputAreaHeight: CGFloat {
        return currentInputHeight + 22  // Input height + padding (top 8 + bottom 8 + extra 6)
    }

    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        if panel == nil {
            panel = makePanel()
        }
        // Reset to input-only state
        currentInputHeight = baseInputFieldHeight
        inputEnabled = false  // Hide input until greeting shown
        inputBlurView?.isHidden = true
        glowView?.isHidden = true
        messagesBlurView?.isHidden = true

        // Show a "thinking" indicator initially
        messagesBlurView?.isHidden = false
        responseLabel?.stringValue = "Thinking..."
        responseLabel?.textColor = thinkingBaseTextColor

        updatePanelHeight(animated: false)

        // Start shimmer animation on "Thinking..." text after layout
        DispatchQueue.main.async { [weak self] in
            self?.startShimmerAnimation()
        }

        positionTopRight()
        panel?.alphaValue = 1.0
        panel?.orderFrontRegardless()
        panel?.makeKey()  // Make panel key to receive keyboard input

        // Don't start keyboard capture until input is enabled
        inputText = ""

        // Don't start inactivity timer until greeting is shown (in enableInput)

        // Notify that chat was opened (for proactive greeting)
        onChatOpened?()
    }

    /// Enable the input field after greeting is shown
    func enableInput() {
        inputEnabled = true
        inputBlurView?.isHidden = false
        glowView?.isHidden = false
        stopShimmerAnimation()  // Stop shimmer since greeting has arrived
        startKeyboardCapture()
        updateInputDisplay()
        startGlowAnimation()
        updatePanelHeight(animated: true)
        resetInactivityTimer()  // Start fade countdown now that greeting is shown
    }

    func hide() {
        stopAllTimers()
        stopKeyboardCapture()
        stopGlowAnimation()
        stopShimmerAnimation()
        panel?.orderOut(nil)
        // Reset state
        messages.removeAll()
        responseLabel?.stringValue = ""
        inputText = ""
        currentInputHeight = baseInputFieldHeight
        inputEnabled = false
    }

    func addMessage(role: String, content: String) {
        // Only show assistant messages (latest response only)
        guard role == "assistant" else { return }

        // Response arrived - no longer waiting
        waitingForResponse = false

        // Stop shimmer animation since we have actual content now
        stopShimmerAnimation()

        // Show messages area
        messagesBlurView?.isHidden = false

        // Update the response label directly (no bubbles, just text)
        responseLabel?.stringValue = content
        responseLabel?.textColor = responseTextColor

        updatePanelHeight(animated: true)
        resetInactivityTimer()
    }

    func showScriptPending(_ pending: Bool) {
        scriptPending = pending
        // Could add visual indicator here (e.g., highlight border)
    }

    /// Call when sending a message to pause inactivity timer
    func setWaitingForResponse(_ waiting: Bool) {
        waitingForResponse = waiting
        if waiting {
            // Stop the timer while waiting
            stopAllTimers()
            // Show "Thinking..." indicator
            responseLabel?.stringValue = "Thinking..."
            responseLabel?.textColor = thinkingBaseTextColor
            updatePanelHeight(animated: true)
            // Start shimmer animation after layout
            DispatchQueue.main.async { [weak self] in
                self?.startShimmerAnimation()
            }
        } else {
            stopShimmerAnimation()
        }
    }

    private func calculateMessagesHeight() -> CGFloat {
        let fullHeight = calculateFullTextHeight()
        guard fullHeight > 0 else { return 0 }
        return min(fullHeight + 24, maxMessagesHeight)  // Add padding, cap at max
    }

    private func calculateFullTextHeight() -> CGFloat {
        guard let label = responseLabel, !label.stringValue.isEmpty else { return 0 }

        // Calculate height needed for the text (uncapped)
        let availableWidth = panelWidth - glowBorderWidth * 2 - 24  // Padding
        let font = NSFont.systemFont(ofSize: 14)
        let textStorage = NSTextStorage(string: label.stringValue)
        textStorage.addAttribute(.font, value: font, range: NSRange(location: 0, length: textStorage.length))

        let textContainer = NSTextContainer(size: NSSize(width: availableWidth, height: CGFloat.greatestFiniteMagnitude))
        textContainer.lineFragmentPadding = 0

        let layoutManager = NSLayoutManager()
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)

        layoutManager.ensureLayout(for: textContainer)
        return layoutManager.usedRect(for: textContainer).height
    }

    private func updatePanelHeight(animated: Bool) {
        guard let panel = panel else { return }

        let messagesHeight = calculateMessagesHeight()
        let hasMessages = messagesHeight > 0
        let inputAreaHeight = inputEnabled ? currentInputAreaHeight : 0
        // Messages area includes the thin border gap (same as glowBorderWidth)
        let messagesAreaHeight = hasMessages ? messagesHeight + glowBorderWidth * 2 : 0
        let totalHeight = max(inputAreaHeight + (hasMessages ? messagesAreaHeight + messageSpacing : 0), messagesAreaHeight)

        var frame = panel.frame
        // Keep top fixed, expand downward
        let topY = frame.origin.y + frame.height
        frame.size.height = totalHeight
        frame.origin.y = topY - totalHeight

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }

        // Input at top of panel
        let inputY = totalHeight - inputAreaHeight

        // Update input blur view frame (at top, with glow border space)
        if let inputBlur = inputBlurView {
            inputBlur.frame = NSRect(
                x: glowBorderWidth,
                y: inputY + glowBorderWidth,
                width: panelWidth - glowBorderWidth * 2,
                height: inputAreaHeight - glowBorderWidth * 2
            )
            // Update input container and field
            if let container = inputContainer, let field = inputField {
                container.frame = NSRect(x: 10, y: 8, width: inputBlur.frame.width - 20, height: currentInputHeight)
                field.frame = NSRect(x: 12, y: 0, width: container.frame.width - 54, height: currentInputHeight)
            }
        }

        // Update glow view position (around input at top)
        if let glow = glowView {
            glow.frame = NSRect(
                x: 0,
                y: inputY,
                width: panelWidth,
                height: inputAreaHeight
            )
        }

        // Messages below input (expanding downward from input)
        let messagesY: CGFloat = 0

        // Update messages border (suspended border around messages area)
        if let border = messagesBorderView {
            border.frame = NSRect(
                x: 0,
                y: messagesY,
                width: panelWidth,
                height: messagesAreaHeight
            )
            border.isHidden = !hasMessages
        }

        // Update messages blur view frame - positioned inside the border with 2px gap
        if let messagesBlur = messagesBlurView {
            messagesBlur.frame = NSRect(
                x: glowBorderWidth,
                y: messagesY + glowBorderWidth,
                width: panelWidth - glowBorderWidth * 2,
                height: max(0, messagesHeight)
            )
            // Update scroll view and label frames
            if let scrollView = responseScrollView, let label = responseLabel {
                let scrollFrame = messagesBlur.bounds.insetBy(dx: 12, dy: 12)
                scrollView.frame = scrollFrame

                // Calculate the full height needed for the text
                let fullTextHeight = calculateFullTextHeight()
                label.frame = NSRect(x: 0, y: 0, width: scrollFrame.width, height: max(scrollFrame.height, fullTextHeight))
            }
            updateShimmerLayoutIfNeeded()
        }
    }

    private func makePanel() -> NSPanel {
        let inputAreaHeight = baseInputAreaHeight

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: inputAreaHeight),
            styleMask: [.borderless],
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
        panel.becomesKeyOnlyIfNeeded = false

        // Main container (transparent, no border)
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: inputAreaHeight + maxMessagesHeight + messageSpacing))
        contentView.autoresizingMask = [.width, .height]
        contentView.wantsLayer = true
        contentView.layer?.masksToBounds = false  // Allow glow to extend outside bounds

        panel.contentView = contentView

        // Suspended border for messages area (thin gray outline with 2px gap, like other popups)
        // Messages will appear below input (at y=0), expanding downward
        let messagesBorder = NSView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: 0))
        messagesBorder.wantsLayer = true
        messagesBorder.layer?.cornerRadius = 16
        messagesBorder.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        messagesBorder.isHidden = true
        contentView.addSubview(messagesBorder)
        self.messagesBorderView = messagesBorder

        // Messages container with blur (hidden initially, inset by glowBorderWidth to create gap)
        let messagesBlur = NSVisualEffectView(frame: NSRect(x: glowBorderWidth, y: glowBorderWidth, width: panelWidth - glowBorderWidth * 2, height: 0))
        messagesBlur.autoresizingMask = [.width]
        messagesBlur.blendingMode = .behindWindow
        messagesBlur.material = .hudWindow
        messagesBlur.state = .active
        messagesBlur.wantsLayer = true
        messagesBlur.layer?.cornerRadius = 14
        messagesBlur.layer?.masksToBounds = true
        messagesBlur.isHidden = true

        let messagesDarkOverlay = NSView(frame: messagesBlur.bounds)
        messagesDarkOverlay.autoresizingMask = [.width, .height]
        messagesDarkOverlay.wantsLayer = true
        messagesDarkOverlay.layer?.backgroundColor = spaceBackground.cgColor
        messagesBlur.addSubview(messagesDarkOverlay)

        // Scroll view for long responses
        let respScrollView = NSScrollView(frame: messagesBlur.bounds.insetBy(dx: 12, dy: 12))
        respScrollView.autoresizingMask = [.width, .height]
        respScrollView.hasVerticalScroller = true
        respScrollView.hasHorizontalScroller = false
        respScrollView.autohidesScrollers = true
        respScrollView.borderType = .noBorder
        respScrollView.drawsBackground = false
        respScrollView.backgroundColor = .clear
        respScrollView.scrollerStyle = .overlay
        respScrollView.contentView.drawsBackground = false

        // Response text view (supports scrolling for long content)
        let respLabel = NSTextField(wrappingLabelWithString: "")
        respLabel.frame = NSRect(x: 0, y: 0, width: respScrollView.contentSize.width, height: 0)
        respLabel.autoresizingMask = [.width]
        respLabel.isEditable = false
        respLabel.isSelectable = true
        respLabel.drawsBackground = false
        respLabel.textColor = responseTextColor
        respLabel.font = NSFont.systemFont(ofSize: 14)
        respLabel.lineBreakMode = .byWordWrapping
        respLabel.maximumNumberOfLines = 0

        respScrollView.documentView = respLabel
        messagesBlur.addSubview(respScrollView)
        self.responseScrollView = respScrollView
        self.responseLabel = respLabel

        self.messagesBlurView = messagesBlur
        contentView.addSubview(messagesBlur)

        // Input container with blur effect - inset for glow border
        let inputContainerHeight: CGFloat = baseInputFieldHeight
        let inputBlur = NSVisualEffectView(frame: NSRect(x: glowBorderWidth, y: glowBorderWidth, width: panelWidth - glowBorderWidth * 2, height: inputContainerHeight + 16))
        inputBlur.autoresizingMask = [.width]
        inputBlur.blendingMode = .behindWindow
        inputBlur.material = .hudWindow
        inputBlur.state = .active
        inputBlur.wantsLayer = true
        inputBlur.layer?.cornerRadius = 14
        inputBlur.layer?.masksToBounds = true

        let inputDarkOverlay = NSView(frame: inputBlur.bounds)
        inputDarkOverlay.autoresizingMask = [.width, .height]
        inputDarkOverlay.wantsLayer = true
        inputDarkOverlay.layer?.backgroundColor = spaceBackground.cgColor

        // Add subtle inner glow that complements the spinning border
        let innerGlowLayer = CAGradientLayer()
        innerGlowLayer.frame = inputDarkOverlay.bounds
        innerGlowLayer.type = .radial
        innerGlowLayer.colors = [
            accentColor.withAlphaComponent(0.08).cgColor,
            NSColor.clear.cgColor
        ]
        innerGlowLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        innerGlowLayer.endPoint = CGPoint(x: 1.0, y: 1.0)
        innerGlowLayer.cornerRadius = 14
        inputDarkOverlay.layer?.addSublayer(innerGlowLayer)

        inputBlur.addSubview(inputDarkOverlay)

        let inputBlurWidth = inputBlur.frame.width
        let inputContainer = NSView(frame: NSRect(x: 10, y: 8, width: inputBlurWidth - 20, height: inputContainerHeight))
        inputContainer.autoresizingMask = [.width]
        inputContainer.wantsLayer = true
        self.inputContainer = inputContainer

        // Text field (display only - keyboard is captured globally)
        let inputField = NSTextField(frame: NSRect(x: 12, y: 0, width: inputBlurWidth - 20 - 54, height: inputContainerHeight))
        let centeredCell = VerticallyCenteredTextFieldCell(textCell: "")
        centeredCell.isEditable = false
        centeredCell.isSelectable = false
        centeredCell.isBordered = false
        centeredCell.drawsBackground = false
        centeredCell.font = NSFont.systemFont(ofSize: 14)
        centeredCell.textColor = .white
        centeredCell.lineBreakMode = .byWordWrapping
        centeredCell.truncatesLastVisibleLine = false
        centeredCell.isScrollable = false
        centeredCell.wraps = true
        inputField.cell = centeredCell
        inputField.autoresizingMask = [.width]
        inputField.maximumNumberOfLines = 0  // Allow unlimited lines for dynamic growth
        self.inputField = inputField
        inputContainer.addSubview(inputField)

        // Send button - minimal arrow (positioned at bottom right of input area)
        let sendBtn = NSButton(frame: NSRect(x: inputBlurWidth - 20 - 38, y: (inputContainerHeight - 24) / 2, width: 24, height: 24))
        sendBtn.bezelStyle = .inline
        sendBtn.isBordered = false
        sendBtn.wantsLayer = true
        sendBtn.title = "→"
        sendBtn.font = NSFont.systemFont(ofSize: 18, weight: .medium)
        sendBtn.contentTintColor = .white.withAlphaComponent(0.7)
        sendBtn.target = self
        sendBtn.action = #selector(handleSendButton)
        sendBtn.autoresizingMask = [.minXMargin]
        inputContainer.addSubview(sendBtn)

        inputBlur.addSubview(inputContainer)
        self.inputBlurView = inputBlur
        contentView.addSubview(inputBlur)

        // Track mouse activity
        let trackingArea = NSTrackingArea(
            rect: contentView.bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        contentView.addTrackingArea(trackingArea)

        return panel
    }

    // MARK: - Inactivity & Fade

    private func resetInactivityTimer() {
        stopAllTimers()
        panel?.alphaValue = 1.0

        inactivityTimer = Timer.scheduledTimer(withTimeInterval: inactivityTimeout, repeats: false) { [weak self] _ in
            self?.startFadeOut()
        }
    }

    private func startFadeOut() {
        // Pulse fade animation - fade in/out a few times before hiding
        let pulseDuration: TimeInterval = 1.0
        let pulseCount = 5
        var currentPulse = 0

        func doPulse() {
            // Fade out (subtle pulse from 100% to 60%)
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = pulseDuration / 2
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                self.panel?.animator().alphaValue = 0.6
            }, completionHandler: {
                // Fade back in
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = pulseDuration / 2
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    self.panel?.animator().alphaValue = 1.0
                }, completionHandler: {
                    currentPulse += 1
                    if currentPulse < pulseCount {
                        doPulse()
                    } else {
                        // Final fade out and hide
                        NSAnimationContext.runAnimationGroup({ context in
                            context.duration = 0.3
                            self.panel?.animator().alphaValue = 0.0
                        }, completionHandler: {
                            self.hide()
                        })
                    }
                })
            })
        }

        doPulse()
    }

    private func stopAllTimers() {
        inactivityTimer?.invalidate()
        inactivityTimer = nil
    }

    @objc func mouseEntered(with event: NSEvent) {
        resetInactivityTimer()
        panel?.makeKey()  // Refocus panel on mouse enter
    }

    @objc func mouseMoved(with event: NSEvent) {
        resetInactivityTimer()
    }

    @objc func mouseDown(with event: NSEvent) {
        resetInactivityTimer()
        panel?.makeKey()  // Ensure focus on click
    }

    // MARK: - Keyboard Capture

    private func startKeyboardCapture() {
        stopKeyboardCapture()

        // Local monitor for when our app/panel is focused
        localKeyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyEvent(event)
            return nil  // Consume the event
        }

        // Global monitor for when other apps are focused
        globalKeyboardMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyEvent(event)
        }
    }

    private func stopKeyboardCapture() {
        if let monitor = localKeyboardMonitor {
            NSEvent.removeMonitor(monitor)
            localKeyboardMonitor = nil
        }
        if let monitor = globalKeyboardMonitor {
            NSEvent.removeMonitor(monitor)
            globalKeyboardMonitor = nil
        }
    }

    private func handleKeyEvent(_ event: NSEvent) {
        resetInactivityTimer()

        let keyCode = event.keyCode
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Escape - close chat
        if keyCode == 53 {
            DispatchQueue.main.async { [weak self] in
                self?.hide()
            }
            return
        }

        // Command key shortcuts
        if modifiers.contains(.command) {
            switch keyCode {
            case 16: // Cmd+Y - execute pending script
                if scriptPending {
                    DispatchQueue.main.async { [weak self] in
                        self?.onExecuteScript?()
                    }
                }
                return
            case 45: // Cmd+N - cancel pending script
                if scriptPending {
                    DispatchQueue.main.async { [weak self] in
                        self?.onCancelScript?()
                    }
                }
                return
            case 0: // Cmd+A - select all (clear and re-type would be the effect, but for now just keep text)
                // In this simple input, select all doesn't make sense visually, but we acknowledge it
                return
            case 8: // Cmd+C - copy
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, !self.inputText.isEmpty else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(self.inputText, forType: .string)
                }
                return
            case 9: // Cmd+V - paste
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    if let pastedString = NSPasteboard.general.string(forType: .string) {
                        // Filter to only valid characters and limit length
                        let filtered = pastedString.filter { $0.isLetter || $0.isNumber || $0.isPunctuation || $0.isWhitespace || $0.isSymbol }
                        self.inputText.append(filtered)
                        self.updateInputDisplay()
                    }
                }
                return
            case 6: // Cmd+Z - undo (clear all as simple undo)
                DispatchQueue.main.async { [weak self] in
                    self?.inputText = ""
                    self?.updateInputDisplay()
                }
                return
            case 7: // Cmd+X - cut
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, !self.inputText.isEmpty else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(self.inputText, forType: .string)
                    self.inputText = ""
                    self.updateInputDisplay()
                }
                return
            default:
                return // Ignore other command shortcuts
            }
        }

        // Enter/Return - send message
        if keyCode == 36 || keyCode == 76 {
            DispatchQueue.main.async { [weak self] in
                self?.sendCurrentMessage()
            }
            return
        }

        // Backspace - delete character
        if keyCode == 51 {
            DispatchQueue.main.async { [weak self] in
                guard let self = self, !self.inputText.isEmpty else { return }
                self.inputText.removeLast()
                self.updateInputDisplay()
            }
            return
        }

        // Regular character input
        if let chars = event.characters, !chars.isEmpty {
            // Ignore control characters
            let char = chars.first!
            if char.isLetter || char.isNumber || char.isPunctuation || char.isWhitespace || char.isSymbol {
                DispatchQueue.main.async { [weak self] in
                    self?.inputText.append(chars)
                    self?.updateInputDisplay()
                }
            }
        }
    }

    private func updateInputDisplay() {
        if inputText.isEmpty {
            inputField?.stringValue = ""
            // Styled placeholder with italic font and subtle color
            let placeholderFont = NSFont.systemFont(ofSize: 14, weight: .light)
            let italicDescriptor = placeholderFont.fontDescriptor.withSymbolicTraits(.italic)
            let italicFont = NSFont(descriptor: italicDescriptor, size: 14) ?? placeholderFont
            inputField?.placeholderAttributedString = NSAttributedString(
                string: "Ask anything...",
                attributes: [
                    .foregroundColor: NSColor.white.withAlphaComponent(0.35),
                    .font: italicFont
                ]
            )
            // Reset to single line height
            if currentInputHeight != baseInputFieldHeight {
                currentInputHeight = baseInputFieldHeight
                updatePanelHeight(animated: true)
            }
        } else {
            inputField?.stringValue = inputText
            // Calculate required height for text
            updateInputHeight()
        }
    }

    private func updateInputHeight() {
        guard inputField != nil else { return }

        // Calculate the height needed for the text
        let availableWidth = panelWidth - glowBorderWidth * 2 - 20 - 54 - 24  // Account for padding and send button

        let font = NSFont.systemFont(ofSize: 14)
        let textStorage = NSTextStorage(string: inputText)
        textStorage.addAttribute(.font, value: font, range: NSRange(location: 0, length: textStorage.length))

        let textContainer = NSTextContainer(size: NSSize(width: availableWidth, height: CGFloat.greatestFiniteMagnitude))
        textContainer.lineFragmentPadding = 0

        let layoutManager = NSLayoutManager()
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)

        layoutManager.ensureLayout(for: textContainer)
        let textHeight = layoutManager.usedRect(for: textContainer).height

        // Calculate new height (minimum single line, maximum capped)
        let newHeight = min(max(textHeight + 8, baseInputFieldHeight), maxInputFieldHeight)

        if abs(newHeight - currentInputHeight) > 1 {
            currentInputHeight = newHeight
            updatePanelHeight(animated: true)
        }
    }

    private func sendCurrentMessage() {
        guard !inputText.isEmpty else { return }
        let message = inputText
        inputText = ""
        updateInputDisplay()
        addMessage(role: "user", content: message)
        onSendMessage?(message)
    }

    @objc private func handleSendButton() {
        sendCurrentMessage()
    }

    // MARK: - Glow Animation

    private var glowView: NSView?

    private func startGlowAnimation() {
        guard let inputBlur = inputBlurView, let contentView = panel?.contentView, let panel = panel else { return }

        // Remove existing glow
        glowView?.removeFromSuperview()

        let inputAreaHeight = currentInputAreaHeight
        let totalHeight = panel.frame.height
        let inputY = totalHeight - inputAreaHeight

        // The glow wraps around the input area (at top of panel)
        let cornerRadius: CGFloat = 16
        let glowFrame = NSRect(
            x: 0,
            y: inputY,
            width: panelWidth,
            height: inputAreaHeight
        )

        let glowContainer = NSView(frame: glowFrame)
        glowContainer.wantsLayer = true
        glowContainer.layer?.cornerRadius = cornerRadius
        glowContainer.layer?.masksToBounds = true  // overflow-hidden

        // HUGE spinning gradient - like inset: -5000%
        let gradientSize = max(glowFrame.width, glowFrame.height) * 100
        let gradientLayer = CAGradientLayer()
        gradientLayer.type = .conic
        gradientLayer.frame = CGRect(
            x: (glowFrame.width - gradientSize) / 2,
            y: (glowFrame.height - gradientSize) / 2,
            width: gradientSize,
            height: gradientSize
        )

        // conic-gradient(from 90deg at 50% 50%, color 0%, transparent 50%, color 100%)
        gradientLayer.colors = [
            accentColor.cgColor,
            NSColor.clear.cgColor,
            accentColor.cgColor
        ]
        gradientLayer.locations = [0.0, 0.5, 1.0]
        gradientLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradientLayer.endPoint = CGPoint(x: 1, y: 0.5)

        // Spin animation - slower for subtlety
        let rotationAnimation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotationAnimation.fromValue = 0
        rotationAnimation.toValue = CGFloat.pi * 2
        rotationAnimation.duration = 5.0
        rotationAnimation.repeatCount = .infinity
        rotationAnimation.timingFunction = CAMediaTimingFunction(name: .linear)
        gradientLayer.add(rotationAnimation, forKey: "spin")

        glowContainer.layer?.addSublayer(gradientLayer)

        // Add behind inputBlur - inputBlur acts as the "inner content" with solid bg
        contentView.addSubview(glowContainer, positioned: .below, relativeTo: inputBlur)
        glowView = glowContainer
    }

    private func stopGlowAnimation() {
        glowView?.removeFromSuperview()
        glowView = nil
    }

    // MARK: - Shimmer Animation for "Thinking..."

    private func startShimmerAnimation() {
        guard let label = responseLabel, !label.stringValue.isEmpty else { return }
        stopShimmerAnimation()

        label.textColor = .clear  // Only the masked layers should be visible during shimmer
        label.layoutSubtreeIfNeeded()
        label.wantsLayer = true

        let font = label.font ?? NSFont.systemFont(ofSize: 14)
        let components = ThinkingShimmerFactory.make(
            bounds: label.bounds,
            text: label.stringValue,
            font: font,
            baseColor: thinkingGradientBaseColor,
            highlightColor: thinkingGradientHighlightColor
        )

        // Base dim fill (keeps a single text baseline, avoids double rendering)
        let baseMask = makeTextMask(for: label)
        let baseLayer = CALayer()
        baseLayer.frame = label.bounds
        baseLayer.backgroundColor = thinkingBaseFillColor.cgColor
        baseLayer.mask = baseMask
        label.layer?.addSublayer(baseLayer)
        shimmerBaseLayer = baseLayer

        // Shimmer streak
        let shimmerMask = makeTextMask(for: label)
        components.gradient.mask = shimmerMask
        label.layer?.addSublayer(components.gradient)
        components.gradient.add(components.animation, forKey: "shimmer")

        shimmerLayer = components.gradient
        shimmerAnimation = components.animation
    }

    private func stopShimmerAnimation() {
        shimmerBaseLayer?.mask = nil
        shimmerBaseLayer?.removeFromSuperlayer()
        shimmerBaseLayer = nil
        shimmerLayer?.removeAllAnimations()
        shimmerLayer?.mask = nil
        shimmerLayer?.removeFromSuperlayer()
        shimmerLayer = nil
        shimmerAnimation = nil

        // Remove the mask
        responseLabel?.layer?.mask = nil

        // Restore visible text color based on current content
        if responseLabel?.stringValue == "Thinking..." {
            responseLabel?.textColor = thinkingBaseTextColor
        } else {
            responseLabel?.textColor = responseTextColor
        }
    }

    private func updateShimmerLayoutIfNeeded() {
        guard let label = responseLabel else { return }
        if let gradient = shimmerLayer {
            gradient.frame = label.bounds
            gradient.mask?.frame = label.bounds
            if let textMask = gradient.mask as? CATextLayer {
                textMask.string = label.stringValue
                textMask.font = label.font
                textMask.fontSize = label.font?.pointSize ?? textMask.fontSize
            }
        }
        if let base = shimmerBaseLayer {
            base.frame = label.bounds
            base.mask?.frame = label.bounds
            if let textMask = base.mask as? CATextLayer {
                textMask.string = label.stringValue
                textMask.font = label.font
                textMask.fontSize = label.font?.pointSize ?? textMask.fontSize
            }
        }
    }

    private func makeTextMask(for label: NSTextField) -> CATextLayer {
        let textLayer = CATextLayer()
        textLayer.frame = label.bounds
        textLayer.string = label.stringValue
        textLayer.font = label.font
        textLayer.fontSize = label.font?.pointSize ?? 14
        textLayer.alignmentMode = .left
        textLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        textLayer.isWrapped = true
        return textLayer
    }

    // MARK: - Messages

    private func refreshMessages() {
        guard let container = messagesContainer else { return }

        container.arrangedSubviews.forEach { $0.removeFromSuperview() }

        for message in messages {
            let bubble = createMessageBubble(message)
            container.addArrangedSubview(bubble)
        }

        DispatchQueue.main.async { [weak self] in
            self?.scrollToBottom()
        }
    }

    private func createMessageBubble(_ message: ChatMessage) -> NSView {
        let isUser = message.role == "user"
        let maxBubbleWidth: CGFloat = 280

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let textField = NSTextField(wrappingLabelWithString: message.content)
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.isEditable = false
        textField.isSelectable = true
        textField.drawsBackground = false
        textField.textColor = .white.withAlphaComponent(0.95)
        textField.font = NSFont.systemFont(ofSize: 13)
        textField.lineBreakMode = .byWordWrapping
        textField.preferredMaxLayoutWidth = maxBubbleWidth - 24

        let wrapper = NSView()
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        wrapper.wantsLayer = true
        wrapper.layer?.cornerRadius = 14
        wrapper.layer?.backgroundColor = (isUser ? messageUserBg : messageAssistantBg).cgColor

        if isUser {
            wrapper.layer?.borderWidth = 1
            wrapper.layer?.borderColor = accentColor.withAlphaComponent(0.3).cgColor
        }

        wrapper.addSubview(textField)
        container.addSubview(wrapper)

        NSLayoutConstraint.activate([
            textField.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 10),
            textField.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -10),
            textField.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 12),
            textField.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -12),
            textField.widthAnchor.constraint(lessThanOrEqualToConstant: maxBubbleWidth - 24),

            wrapper.topAnchor.constraint(equalTo: container.topAnchor),
            wrapper.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            container.widthAnchor.constraint(equalToConstant: 340)
        ])

        if isUser {
            wrapper.trailingAnchor.constraint(equalTo: container.trailingAnchor).isActive = true
        } else {
            wrapper.leadingAnchor.constraint(equalTo: container.leadingAnchor).isActive = true
        }

        return container
    }

    private func scrollToBottom() {
        guard let scrollView = scrollView, let container = messagesContainer else { return }
        let maxY = container.frame.maxY - scrollView.contentView.bounds.height
        if maxY > 0 {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: maxY))
        }
    }

    private func positionTopRight() {
        guard let panel = panel, let screen = NSScreen.main else { return }
        let margin: CGFloat = 16
        var frame = panel.frame
        frame.origin = NSPoint(
            x: screen.visibleFrame.maxX - frame.width - margin,
            y: screen.visibleFrame.maxY - frame.height - margin
        )
        panel.setFrame(frame, display: false)
    }

}
