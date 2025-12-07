# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is `neb-screen-keys`, a macOS app that provides AI-assisted task automation through screen monitoring and context awareness. The app monitors user activity, captures screen context, uses Grok AI to understand tasks, retrieves relevant memories from Nebula, and generates/executes AppleScript automation.

## Build Configuration

### Build Location
The project is configured to build to a **fixed location** to avoid macOS permission issues:
- Debug builds: `build/Debug/neb-screen-keys.app`
- Release builds: `build/Release/neb-screen-keys.app`

This is set via `CONFIGURATION_BUILD_DIR = "$(SRCROOT)/build/$(CONFIGURATION)"` in project.pbxproj.

### Code Signing
**Debug builds have code signing DISABLED** (`CODE_SIGN_IDENTITY = "-"`) to prevent macOS from re-requesting permissions on every rebuild. This is critical because:
- Each rebuild with automatic signing generates a new code signature
- macOS tracks permissions by bundle ID + code signature
- Without consistent signing, permissions are lost on every rebuild

**Release builds can use automatic signing** for distribution.

### App Sandbox
**App Sandbox is DISABLED** (`ENABLE_APP_SANDBOX = NO`) because the app requires:
- Unrestricted network access (Grok and Nebula APIs)
- Screen recording via ScreenCaptureKit
- Accessibility for CGEventTap
- AppleScript execution

The sandbox prevents DNS resolution and other critical functionality.

## Build and Development Commands

### Building
```bash
# Build the app (output: build/Debug/neb-screen-keys.app)
xcodebuild -project neb-screen-keys.xcodeproj -scheme neb-screen-keys -configuration Debug build

# Build for release (output: build/Release/neb-screen-keys.app)
xcodebuild -project neb-screen-keys.xcodeproj -scheme neb-screen-keys -configuration Release build

# Clean build folder
xcodebuild -project neb-screen-keys.xcodeproj -scheme neb-screen-keys clean
```

### Testing
```bash
# Run all tests
xcodebuild test -project neb-screen-keys.xcodeproj -scheme neb-screen-keys

# Run specific test target
xcodebuild test -project neb-screen-keys.xcodeproj -scheme neb-screen-keys -only-testing:neb-screen-keysTests

# Run UI tests
xcodebuild test -project neb-screen-keys.xcodeproj -scheme neb-screen-keys -only-testing:neb-screen-keysUITests
```

### Running
```bash
# Run from Xcode-built binary (after building)
open build/Debug/neb-screen-keys.app
```

## Environment Configuration

The app requires API keys configured via environment variables. EnvLoader (EnvLoader.swift:12-32) searches for `.env` files in this order:
1. `~/.config/neb-screen-keys/.env`
2. `./.env` (project root)

Required environment variables:
- `GROK_API_KEY`: API key for Grok AI (x.ai)
- `NEBULA_API_KEY`: API key for Nebula memory service
- `NEBULA_COLLECTION_ID`: Collection ID for Nebula (defaults to `aec926de-022c-47ac-8ae3-ddcd7febf68c`)

Example `.env`:
```
GROK_API_KEY=your_grok_key
NEBULA_API_KEY=your_nebula_key
NEBULA_COLLECTION_ID=your_collection_id
```

## Architecture Overview

### Core Coordinator Pattern
The app uses a coordinator architecture with `AppCoordinator` (AppCoordinator.swift:9) as the central orchestrator:

- **AppCoordinator**: Orchestrates the entire workflow - monitors events, captures screens, annotates context, manages task state, and executes automation
- **Flow**: Event → Screen Capture → Grok Annotation → Memory Search → User Decision → Execution → Memory Storage

### Service Layer
Four main services handle distinct responsibilities:

1. **ScreenCaptureService** (ScreenCaptureService.swift:10): Captures screen images using ScreenCaptureKit (macOS 14+), returns `ScreenFrame` with image + app metadata

2. **AnnotatorService** (AnnotatorService.swift:8): Sends screen captures to Grok AI with base64-encoded PNG, receives structured JSON with task analysis (task_label, confidence, summary, app, window_title)

3. **ExecutorService** (ExecutorService.swift:8): Plans and executes tasks by querying Nebula for relevant memories, prompting Grok to generate numbered plans + AppleScript, extracting and executing AppleScript from triple-backtick fenced blocks

4. **EventMonitoring** (EventMonitoring.swift:8-73): Two monitors - `EventMonitor` watches for keyboard shortcuts (Cmd+Tab, Cmd+Space), `KeystrokeMonitor` uses CGEventTap to detect any keydown events

### Client Integrations
- **GrokClient** (GrokClient.swift:30): HTTP client for x.ai API, sends POST requests to `/v1/responses` with messages and optional image attachments
- **NebulaClient** (NebulaClient.swift:8): JSON-RPC client for Nebula memory service, supports `add_memory` and `search_memories` methods

### State Management
- **TaskStateStore** (Models.swift:23): Tracks current task ID, declined tasks, and completed tasks using SHA256 hashes of (taskLabel|app|windowTitle)
- **Task Identity**: Tasks are deduplicated by hashing context to prevent duplicate prompts for same task

### UI Layer
- **OverlayController** (OverlayController.swift:8): Manages two NSPanel overlays - suggestion panel (near cursor) and decision panel (top-right), provides Yes/No callbacks for task execution

## Key Data Flows

### Task Detection Flow
1. Event trigger (shortcut/keystroke/launch) → `AppCoordinator.maybeAnnotate()`
2. Capture screen via `ScreenCaptureService.captureActiveScreen()` → `ScreenFrame`
3. Convert image to PNG + base64 → send to Grok via `AnnotatorService.annotate()`
4. Parse Grok JSON response → `AnnotatedContext`
5. Generate stable task ID via SHA256 hash
6. Check if task was previously declined/completed → skip if so
7. Push context to Nebula memory
8. Show overlay if new task detected

### Task Execution Flow
1. User clicks "Yes" on overlay → `AppCoordinator.executeCurrentTask()`
2. Re-capture screen and annotate for latest context
3. Search Nebula memories with task label via `NebulaClient.searchMemories()`
4. Send context + memories to Grok → receive plan with AppleScript
5. Extract AppleScript from triple-backtick code block (```applescript)
6. Execute via `NSAppleScript.executeAndReturnError()`
7. Store execution plan in Nebula
8. Mark task as completed in state store

## Important Implementation Details

### Async Patterns
- `ScreenCaptureService.captureActiveScreen()` uses Swift async/await with ScreenCaptureKit
- `AnnotatorService.annotate()` bridges callback-based `GrokClient` to async via `withCheckedContinuation`
- `AppCoordinator` uses `Task {}` blocks for non-blocking coordinator methods that must support optional self binding

### Screen Capture Specifics
- Uses `OneShotFrameGrabber` (ScreenCaptureService.swift:53) that implements `SCStreamOutput` to capture single frame
- `firstFrame()` uses checked continuation that resolves when `stream(_:didOutputSampleBuffer:)` receives first frame
- Captures entire display at native resolution with BGRA pixel format

### AppleScript Extraction
- `ExecutorService.executeAppleScriptIfPresent()` searches for ```applescript markers
- Extracts script body between opening marker's upperBound and closing marker's lowerBound
- Silent execution - errors logged but don't block flow

### Memory Integration
- All task contexts pushed to Nebula with metadata: task_id, task_label, app, window_title, confidence, timestamp
- Execution plans stored separately with type="execution_plan"
- Search retrieves top 5 memories by relevance to inform Grok's planning

## macOS Permissions Required

The app requires these permissions to function:

### Required Permissions
1. **Screen Recording** (for ScreenCaptureKit capture)
2. **Accessibility** (for CGEventTap keyboard monitoring)
3. **Network access** (for Grok and Nebula API calls - automatic, no prompt)

### First-Time Setup
After building the app, grant permissions manually:

1. **Open System Settings → Privacy & Security → Screen Recording**
   - Click the **+** button
   - Press **Cmd+Shift+G** to open "Go to folder"
   - Navigate to: `<project-root>/build/Debug/neb-screen-keys.app`
   - Add the app and toggle it **ON**

2. **Open System Settings → Privacy & Security → Accessibility**
   - Click the **+** button
   - Press **Cmd+Shift+G**
   - Navigate to: `<project-root>/build/Debug/neb-screen-keys.app`
   - Add the app and toggle it **ON**

**Important**: Because the build location is fixed, you only need to grant permissions **once**. They will persist across rebuilds.

## Testing Strategy

- **neb-screen-keysTests**: Unit tests for core logic
- **neb-screen-keysUITests**: UI automation tests for overlay interactions
