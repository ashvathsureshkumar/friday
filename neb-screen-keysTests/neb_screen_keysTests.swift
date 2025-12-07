//
//  neb_screen_keysTests.swift
//  neb-screen-keysTests
//
//  Created by Ashvath Suresh Kumar on 12/6/25.
//

import AppKit
import Testing
@testable import neb_screen_keys

struct neb_screen_keysTests {

    @Test func shimmerFactoryBuildsGradientAndMask() throws {
        let bounds = CGRect(x: 0, y: 0, width: 180, height: 22)
        let font = NSFont.systemFont(ofSize: 14)

        let baseColor = NSColor(red: 0.12, green: 0.1, blue: 0.7, alpha: 1.0)
        let highlightColor = baseColor.highlight(withLevel: 0.5) ?? baseColor

        let components = ThinkingShimmerFactory.make(
            bounds: bounds,
            text: "Thinking...",
            font: font,
            baseColor: baseColor,
            highlightColor: highlightColor
        )

        #expect(components.gradient.frame == bounds)
        #expect(components.gradient.startPoint == CGPoint(x: 0, y: 0.5))
        #expect(components.gradient.endPoint == CGPoint(x: 1, y: 0.5))

        let locations = components.gradient.locations as? [NSNumber]
        #expect(locations == [
            NSNumber(value: -0.4),
            NSNumber(value: -0.2),
            NSNumber(value: 0.0)
        ])

        #expect(components.mask.string as? String == "Thinking...")
        #expect(components.mask.fontSize == font.pointSize)
    }

    @Test func shimmerAnimationLoopsSmoothly() throws {
        let font = NSFont.systemFont(ofSize: 14)
        let baseColor = NSColor(red: 0.12, green: 0.1, blue: 0.7, alpha: 1.0)
        let highlightColor = baseColor.highlight(withLevel: 0.5) ?? baseColor

        let components = ThinkingShimmerFactory.make(
            bounds: CGRect(x: 0, y: 0, width: 200, height: 22),
            text: "Thinking...",
            font: font,
            baseColor: baseColor,
            highlightColor: highlightColor,
            duration: 0.8
        )

        let animation = components.animation
        let fromLocations = animation.fromValue as? [NSNumber]
        let toLocations = animation.toValue as? [NSNumber]

        #expect(fromLocations == [
            NSNumber(value: -0.4),
            NSNumber(value: -0.2),
            NSNumber(value: 0.0)
        ])
        #expect(toLocations == [
            NSNumber(value: 1.0),
            NSNumber(value: 1.2),
            NSNumber(value: 1.4)
        ])

        #expect(animation.duration == 0.8)
        #expect(animation.repeatCount == Float.infinity)
        #expect(animation.isRemovedOnCompletion == false)
        #expect(animation.timingFunction?.name == .linear)
    }
}
