//
//  WelcomeAnimationController.swift
//  neb-screen-keys
//

import Cocoa
import QuartzCore

final class WelcomeAnimationController {
    private var window: NSWindow?
    private let animationDuration: TimeInterval = 2.5
    
    // Nebula colors
    private let accentColor = NSColor(red: 0x1d/255.0, green: 0x10/255.0, blue: 0xb3/255.0, alpha: 1.0)
    private let spaceBackground = NSColor(red: 0x07/255.0, green: 0x0B/255.0, blue: 0x20/255.0, alpha: 0.95)
    
    func show(completion: @escaping () -> Void) {
        guard let screen = NSScreen.main else {
            completion()
            return
        }
        
        // Create fullscreen window
        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .screenSaver + 1
        window.ignoresMouseEvents = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        
        let contentView = NSView(frame: screen.frame)
        contentView.wantsLayer = true
        window.contentView = contentView
        
        // Background gradient
        let backgroundLayer = CAGradientLayer()
        backgroundLayer.frame = contentView.bounds
        backgroundLayer.colors = [
            spaceBackground.cgColor,
            NSColor(red: 0x0d/255.0, green: 0x15/255.0, blue: 0x35/255.0, alpha: 0.95).cgColor
        ]
        backgroundLayer.startPoint = CGPoint(x: 0.5, y: 0)
        backgroundLayer.endPoint = CGPoint(x: 0.5, y: 1)
        contentView.layer?.addSublayer(backgroundLayer)
        
        // Create animated particles
        for _ in 0..<50 {
            let particle = createParticle(in: contentView.bounds)
            contentView.layer?.addSublayer(particle)
            animateParticle(particle, in: contentView.bounds)
        }
        
        // Welcome text container
        let centerX = screen.frame.width / 2
        let centerY = screen.frame.height / 2
        
        // Main text
        let welcomeLabel = NSTextField(labelWithString: "Welcome Back")
        welcomeLabel.font = NSFont.systemFont(ofSize: 72, weight: .bold)
        welcomeLabel.textColor = .white
        welcomeLabel.alignment = .center
        welcomeLabel.frame = NSRect(x: centerX - 300, y: centerY + 40, width: 600, height: 100)
        welcomeLabel.alphaValue = 0
        contentView.addSubview(welcomeLabel)
        
        // Subtitle
        let subtitleLabel = NSTextField(labelWithString: "F.R.I.D.A.Y. is ready")
        subtitleLabel.font = NSFont.systemFont(ofSize: 28, weight: .medium)
        subtitleLabel.textColor = accentColor.withAlphaComponent(0.9)
        subtitleLabel.alignment = .center
        subtitleLabel.frame = NSRect(x: centerX - 300, y: centerY - 20, width: 600, height: 40)
        subtitleLabel.alphaValue = 0
        contentView.addSubview(subtitleLabel)
        
        // Animated circle
        let circleLayer = CAShapeLayer()
        let circlePath = NSBezierPath(ovalIn: NSRect(x: centerX - 100, y: centerY - 100, width: 200, height: 200))
        circleLayer.path = circlePath.cgPath
        circleLayer.fillColor = NSColor.clear.cgColor
        circleLayer.strokeColor = accentColor.cgColor
        circleLayer.lineWidth = 3
        circleLayer.opacity = 0
        contentView.layer?.addSublayer(circleLayer)
        
        // Glow effect
        let glowLayer = CAShapeLayer()
        glowLayer.path = circlePath.cgPath
        glowLayer.fillColor = NSColor.clear.cgColor
        glowLayer.strokeColor = accentColor.cgColor
        glowLayer.lineWidth = 20
        glowLayer.opacity = 0
        glowLayer.shadowColor = accentColor.cgColor
        glowLayer.shadowRadius = 30
        glowLayer.shadowOpacity = 0.8
        glowLayer.shadowOffset = .zero
        contentView.layer?.insertSublayer(glowLayer, below: circleLayer)
        
        self.window = window
        window.makeKeyAndOrderFront(nil)
        
        // Animate sequence
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.8
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            
            // Fade in circle
            circleLayer.opacity = 1.0
            glowLayer.opacity = 0.3
            
            // Scale animation
            let scaleAnimation = CABasicAnimation(keyPath: "transform.scale")
            scaleAnimation.fromValue = 0.3
            scaleAnimation.toValue = 1.0
            scaleAnimation.duration = 0.8
            scaleAnimation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            circleLayer.add(scaleAnimation, forKey: "scale")
            glowLayer.add(scaleAnimation, forKey: "scale")
        }
        
        // Pulse animation for circle
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            let pulseAnimation = CABasicAnimation(keyPath: "transform.scale")
            pulseAnimation.fromValue = 1.0
            pulseAnimation.toValue = 1.1
            pulseAnimation.duration = 1.0
            pulseAnimation.autoreverses = true
            pulseAnimation.repeatCount = .infinity
            pulseAnimation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            circleLayer.add(pulseAnimation, forKey: "pulse")
            
            let glowPulse = CABasicAnimation(keyPath: "opacity")
            glowPulse.fromValue = 0.3
            glowPulse.toValue = 0.6
            glowPulse.duration = 1.0
            glowPulse.autoreverses = true
            glowPulse.repeatCount = .infinity
            glowPulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            glowLayer.add(glowPulse, forKey: "glowPulse")
        }
        
        // Fade in text
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.6
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                welcomeLabel.animator().alphaValue = 1.0
            }
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.6
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                subtitleLabel.animator().alphaValue = 1.0
            }
        }
        
        // Fade out and dismiss
        DispatchQueue.main.asyncAfter(deadline: .now() + animationDuration) {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.5
                contentView.animator().alphaValue = 0
            }, completionHandler: {
                window.orderOut(nil)
                self.window = nil
                completion()
            })
        }
    }
    
    private func createParticle(in bounds: NSRect) -> CALayer {
        let size = CGFloat.random(in: 2...4)
        let particle = CALayer()
        particle.frame = NSRect(
            x: CGFloat.random(in: 0...bounds.width),
            y: CGFloat.random(in: 0...bounds.height),
            width: size,
            height: size
        )
        particle.backgroundColor = accentColor.withAlphaComponent(CGFloat.random(in: 0.3...0.7)).cgColor
        particle.cornerRadius = size / 2
        return particle
    }
    
    private func animateParticle(_ particle: CALayer, in bounds: NSRect) {
        // Random movement
        let moveAnimation = CABasicAnimation(keyPath: "position")
        moveAnimation.fromValue = particle.position
        moveAnimation.toValue = NSValue(point: NSPoint(
            x: CGFloat.random(in: 0...bounds.width),
            y: CGFloat.random(in: 0...bounds.height)
        ))
        moveAnimation.duration = TimeInterval.random(in: 3...6)
        moveAnimation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        moveAnimation.autoreverses = true
        moveAnimation.repeatCount = .infinity
        particle.add(moveAnimation, forKey: "move")
        
        // Twinkle effect
        let opacityAnimation = CABasicAnimation(keyPath: "opacity")
        opacityAnimation.fromValue = 0.3
        opacityAnimation.toValue = 1.0
        opacityAnimation.duration = TimeInterval.random(in: 1...2)
        opacityAnimation.autoreverses = true
        opacityAnimation.repeatCount = .infinity
        particle.add(opacityAnimation, forKey: "twinkle")
    }
}

