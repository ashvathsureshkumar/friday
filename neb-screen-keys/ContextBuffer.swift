//
//  ContextBuffer.swift
//  neb-screen-keys
//

import Foundation

/// Represents a batch of buffered context data ready for consumption
struct BufferBatch {
    let keystrokes: String
    let screenFrame: ScreenFrame?
    let timestamp: Date
}

/// Thread-safe actor that buffers real-time activity for periodic AI processing
actor ContextBufferService {
    // MARK: - State

    /// Accumulated keystrokes since last consumption
    private var keystrokeBuffer: String = ""

    /// Latest screen frame captured
    private var latestScreenFrame: ScreenFrame?

    /// Timestamp of last screen frame update
    private var lastScreenUpdate: Date?

    // MARK: - Public Methods

    /// Append keystrokes to the buffer
    /// - Parameter keystrokes: String representing recent keystroke activity
    func append(keystrokes: String) {
        keystrokeBuffer += keystrokes
        Logger.shared.log(.buffer, "Appended '\(keystrokes)'. Buffer size: \(keystrokeBuffer.count) chars")
    }

    /// Update the latest screen frame
    /// - Parameter frame: The newest screen capture
    func updateLatestScreen(_ frame: ScreenFrame) {
        latestScreenFrame = frame
        lastScreenUpdate = Date()
        Logger.shared.log(.buffer, "Screen frame updated. App: \(frame.appName), Window: \(frame.windowTitle)")
    }

    /// Consume and clear the buffer, returning accumulated data
    /// - Returns: BufferBatch if data exists, nil otherwise
    func consumeAndClear() -> BufferBatch? {
        // Only return a batch if we have either keystrokes or a screen frame
        guard !keystrokeBuffer.isEmpty || latestScreenFrame != nil else {
            Logger.shared.log(.buffer, "Consume requested but buffer is empty")
            return nil
        }

        let hasScreen = latestScreenFrame != nil
        let keystrokeCount = keystrokeBuffer.count

        let batch = BufferBatch(
            keystrokes: keystrokeBuffer,
            screenFrame: latestScreenFrame,
            timestamp: Date()
        )

        // Clear keystroke buffer but keep screen frame as baseline
        keystrokeBuffer = ""

        Logger.shared.log(.buffer, "📤 Batch consumed: \(keystrokeCount) chars + \(hasScreen ? "ScreenFrame ✓" : "No screen ✗"). Buffer cleared.")

        return batch
    }

    /// Check if buffer has meaningful data
    /// - Returns: True if buffer contains keystrokes or a screen frame
    func hasData() -> Bool {
        return !keystrokeBuffer.isEmpty || latestScreenFrame != nil
    }

    /// Get buffer statistics for debugging
    /// - Returns: Tuple of (keystroke count, has screen frame, last update time)
    func getStats() -> (keystrokeCount: Int, hasScreen: Bool, lastUpdate: Date?) {
        return (keystrokeBuffer.count, latestScreenFrame != nil, lastScreenUpdate)
    }
}
