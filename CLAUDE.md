# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is `neb-screen-keys`, a macOS app that provides AI-assisted task automation through screen monitoring and context awareness. The app monitors user activity, captures screen context, uses Grok AI to understand tasks, retrieves relevant memories from Nebula, and generates/executes interactive AppleScript automation.

The app uses a **Producer-Consumer architecture** where user events are buffered at high speed (producer) and processed by AI every 3 seconds (consumer), preventing performance degradation while maintaining context awareness.

## Build Configuration

### Build Location
The project is configured to build to a **fixed location** to avoid macOS permission issues:
- Debug builds: `build/Debug/neb-screen-keys.app`
- Release builds: `build/Release/neb-screen-keys.app`

This is set via `CONFIGURATION_BUILD_DIR = "$(SRCROOT)/build/$(CONFIGURATION)"` in project.pbxproj.

### Code Signing
**Debug builds have code signing DISABLED** (`CODE_SIGN_IDENTITY = "-"`, `CODE_SIGN_STYLE = Manual`) to prevent macOS from re-requesting permissions on every rebuild. This is critical because:
- Each rebuild with automatic signing generates a new code signature
- macOS tracks permissions by bundle ID + code signature
- Without consistent signing, permissions are lost on every rebuild
- **Permissions now persist across rebuilds in Debug mode**

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

# View logs in real-time (optional)
log stream --predicate 'subsystem == "com.apple.console"' --level debug
```

## Environment Configuration

The app requires API keys configured via environment variables. EnvLoader (EnvLoader.swift:12-44) searches for `.env` files in this order:
1. `~/.config/neb-screen-keys/.env` (recommended)
2. `./.env` (project root)

Required environment variables:
- `GROK_API_KEY`: API key for Grok AI (x.ai) - should start with `xai-`
- `NEBULA_API_KEY`: API key for Nebula memory service - should start with `neb_`
- `NEBULA_COLLECTION_ID`: Collection ID for Nebula (UUID format)

Example `.env`:
```bash
GROK_API_KEY=xai-abc123def456...
NEBULA_API_KEY=neb_sk_xyz789...
NEBULA_COLLECTION_ID=cd8e4a41-de13-46ac-8229-81c84b96dab3
```

**Note:** API keys are stripped of any "Bearer " prefix automatically by the clients.

## Architecture Overview

### Core Coordinator Pattern
The app uses a **multi-layered Producer-Consumer** architecture with `AppCoordinator` (AppCoordinator.swift:9) as the central orchestrator:

- **AppCoordinator**: Orchestrates the entire workflow using a three-phase approach:
  - **Phase 1 - Producer (High-Speed)**: Event buffering (keystrokes, shortcuts, screen captures)
  - **Phase 2 - Annotator (AI Pace)**: Processes buffer every 3 seconds, sends to Grok vision AI for analysis
  - **Phase 3 - Fan-Out (Parallel Consumers)**: Broadcasts annotations to multiple independent consumers via `AnnotationBufferService`
- **Flow**: Event → Context Buffer → (3s) → Annotator → **Annotation Buffer** → [Nebula Consumer + Execution Agent Consumer]

### Annotation Buffer (Fan-Out Architecture)
- **AnnotationBufferService** (Models.swift:56): Actor-based multicast streaming buffer
  - Supports multiple concurrent subscribers via `AsyncStream<AnnotatedContext>`
  - Uses `AsyncStream.Continuation` for each subscriber
  - `publish()` broadcasts one annotation to all active consumers
  - `makeStream()` creates new subscription stream for each consumer
  - Thread-safe with Swift actor isolation
  - Automatic cleanup when streams terminate

### Consumer Services
1. **Nebula Consumer** (AppCoordinator.swift:184):
   - Subscribes to annotation buffer stream
   - Stores every annotation to Nebula memory service
   - Runs independently without blocking other consumers
   - Generates comprehensive context with metadata for semantic search

2. **Execution Agent Consumer** (ExecutionAgent.swift:9):
   - Subscribes to annotation buffer stream
   - Evaluates if annotations require user automation
   - Checks declined/completed task history
   - Triggers UI overlays for new tasks
   - Generates AI suggestion previews asynchronously
   - Runs on main thread for UI updates

### Service Layer
Four main services handle distinct responsibilities:

1. **ScreenCaptureService** (ScreenCaptureService.swift:10): 
   - Captures fresh screen images using ScreenCaptureKit (macOS 14+)
   - Returns `ScreenFrame` with image + app metadata
   - Uses `OneShotFrameGrabber` that captures a single frame per request (no caching)
   - Each capture is fresh and represents current screen state

2. **AnnotatorService** (AnnotatorService.swift:25): 
   - Sends screen captures to Grok AI with base64-encoded PNG images
   - Uses `grok-2-vision-1212` model for vision + language understanding
   - Receives structured JSON with task analysis (task_label, confidence, summary, app, window_title)
   - Parses response into `AnnotatedContext` with fallback handling

3. **ExecutorService** (ExecutorService.swift:8): 
   - Generates quick suggestion previews for the cursor overlay using `grok-4-fast`
   - Plans and executes tasks by querying Nebula for relevant memories
   - Prompts Grok with comprehensive context (task details, keystroke patterns, historical memories)
   - Generates **actionable, interactive AppleScripts** with real UI automation:
     - Keyboard input (typing, shortcuts, key codes)
     - Mouse clicks and cursor movement
     - Clipboard operations (copy/paste)
     - Menu navigation and window management
   - Extracts and executes AppleScript from triple-backtick fenced blocks
   - Uses `grok-4-fast` model for execution planning

4. **EventMonitoring** (EventMonitoring.swift:8-83): 
   - Two monitors working in parallel:
     - `EventMonitor`: Watches for specific keyboard shortcuts (Cmd+Tab, Cmd+Space)
     - `KeystrokeMonitor`: Uses CGEventTap to detect all keydown events
   - Both feed into the context buffer for AI processing

### Buffer System
- **ContextBufferService** (ContextBuffer.swift:16): Thread-safe actor that buffers real-time activity
  - Accumulates keystrokes as strings (with shortcut markers like `[SHORTCUT:cmd-tab]`)
  - Stores latest screen frame (updated on each capture, no caching)
  - Consumed and cleared every 3 seconds by the AI processing loop
  - Returns `BufferBatch` with keystrokes + screen + timestamp

- **AnnotationBufferService** (Models.swift:56): Thread-safe actor for fan-out streaming
  - Multicasts `AnnotatedContext` to multiple subscribers
  - Each consumer gets independent `AsyncStream<AnnotatedContext>`
  - Non-blocking: Annotator publishes and continues immediately
  - Parallel consumption: Nebula storage and Execution Agent run concurrently
  - Automatic subscriber lifecycle management

### Client Integrations
- **GrokClient** (GrokClient.swift:78): 
  - HTTP client for x.ai API
  - Sends POST requests to `/v1/chat/completions` with OpenAI-compatible format
  - Supports vision via image_url content parts with base64 data URLs
  - Uses models: `grok-2-vision-1212` (vision), `grok-4-fast` (text)
  - Returns `ChatCompletionResponse` with standard OpenAI format
  
- **NebulaClient** (NebulaClient.swift:8): 
  - REST API client for Nebula memory service (https://api.nebulacloud.app)
  - Uses proper Codable structs for type-safe API communication
  - **Store Memory**: POST `/v1/memories` with `NebulaMemoryRequest`
    - Fields: `content`, `metadata` (string values only), `collection_ref`, `engram_type` ("document")
  - **Search**: POST `/v1/search` with `NebulaSearchRequest`
    - Fields: `query`, `collection_ids` (array), `limit`
  - Converts all metadata values to strings for API compatibility
  - Comprehensive error logging with HTTP status codes and response bodies

### State Management
- **TaskStateStore** (Models.swift:23): Tracks current task ID, declined tasks, and completed tasks
  - Uses SHA256 hashes of `(taskLabel|app|windowTitle)` for stable task identity
  - Prevents duplicate prompts for same task across sessions
  - Maintains declined and completed sets for smart filtering

### UI Layer
- **OverlayController** (OverlayController.swift:8): Manages two NSPanel overlays
  - **Suggestion Panel** (near cursor): 
    - 320x80 multi-line panel
    - Shows AI-generated action preview (e.g., "Type and run 'brew restart postgresql'")
    - Initially shows "Thinking..." while Grok generates suggestion
    - Updates asynchronously with specific, actionable suggestion
  - **Decision Panel** (top-right):
    - 300x110 panel with clear task description
    - Shows "Execute automation for: [Task Label]"
    - Two buttons: "Yes, Execute" and "Not Now"
    - Multi-line wrapping for long task names

### Logging System
- **Logger** (Logger.swift:33): Centralized logging with categories
  - Categories: Event, Buffer, Annotator, Executor, Nebula, Flow, Capture, Stream, System
  - Format: `[HH:mm:ss.SSS] [Category] message`
  - **No emojis** - clean, professional output
  - Smart truncation: Limits large payloads (base64 images, JSON responses) to summaries
  - **Stream category**: Logs annotation buffer broadcasting and consumer activity

## Key Data Flows

### Producer Flow (High-Speed Event Capture)
1. User input detected (keystroke or shortcut)
2. `ContextBufferService.append(keystrokes)` - Buffer the activity marker
3. `captureAndBuffer()` triggered with throttling (500ms minimum interval)
4. `ScreenCaptureService.captureActiveScreen()` - Fresh screen capture using ScreenCaptureKit
5. `ContextBufferService.updateLatestScreen()` - Store latest frame
6. **Buffer now contains**: accumulated keystrokes + latest screen frame

### Consumer Flow (AI Processing Loop - 3 Second Interval)
1. Timer tick every 3 seconds
2. Check if `ContextBufferService.hasData()`
3. If data exists: `consumeAndClear()` → get `BufferBatch`
4. Send batch to `AnnotatorService.annotate()`
5. Grok vision model analyzes screen + keystroke context
6. Parse response into `AnnotatedContext`
7. **Publish to AnnotationBufferService** → broadcasts to all consumers
8. **Parallel Consumer Execution**:
   - **Nebula Consumer**: Stores annotation to memory service
   - **Execution Agent Consumer**: Evaluates if automation is needed

### Nebula Consumer Flow (Parallel to Execution Agent)
1. Subscribe to `AnnotationBufferService.makeStream()`
2. For each annotation received:
3. Generate stable task ID via SHA256 hash
4. Build comprehensive content (task details + AI analysis)
5. Create metadata dictionary (task_id, confidence, timestamp, type)
6. Call `NebulaClient.addMemory()` - stores via REST API
7. Log success/failure (accepts 200-299 status codes, including 202 Accepted)

### Execution Agent Consumer Flow (Parallel to Nebula)
1. Subscribe to `AnnotationBufferService.makeStream()`
2. For each annotation received:
3. Generate stable task ID
4. Check `TaskStateStore` for declined/completed status
5. If task was handled before → skip
6. If new task → Update state and trigger UI:
   - Show **Decision Panel** (top-right) with task label
   - Show **Suggestion Panel** with "Thinking..."
   - Generate AI suggestion via `ExecutorService.generateSuggestionPreview()`
   - Update suggestion panel with actionable preview

### Task Execution Flow
1. User clicks "Yes, Execute" on overlay → `AppCoordinator.executeCurrentTask()`
2. Consume current buffer state (or capture fresh screen if empty)
3. Re-annotate with latest context via `AnnotatorService.annotate()`
4. Search Nebula memories with task label via `NebulaClient.searchMemories()`
   - Retrieves top 5 relevant memories from past similar tasks
5. Build comprehensive execution prompt with:
   - Current task context (label, app, window, AI analysis, confidence)
   - User activity signals (keystroke count, shortcuts detected, activity patterns)
   - Historical context (retrieved memories from Nebula)
   - Task-specific automation patterns (terminal, code editor, browser, etc.)
6. Send to Grok via `ExecutorService.planAndExecute()`
7. Grok generates:
   - Numbered action plan (3-5 specific steps)
   - Interactive AppleScript with System Events (typing, clicking, pasting)
8. Extract AppleScript from ```applescript code block
9. Execute via `NSAppleScript.executeAndReturnError()`
10. Store execution plan in Nebula with metadata
11. Mark task as completed in state store
12. Hide all overlays

## Important Implementation Details

### Multi-Layered Architecture Benefits
The app uses a **three-phase architecture** with clear separation of concerns:

1. **Phase 1 - Context Buffer** (High-speed event collection):
   - Captures user input at native speed without blocking
   - Throttles screen captures to 500ms minimum interval
   - Accumulates keystrokes and latest screen frame

2. **Phase 2 - Annotator** (AI processing every 3 seconds):
   - Consumes buffer batch and sends to Grok vision AI
   - Processes in background without blocking UI
   - Publishes `AnnotatedContext` to annotation buffer

3. **Phase 3 - Fan-Out Consumers** (Parallel processing):
   - **Decoupled**: Annotator doesn't know about consumers
   - **Parallel**: Nebula storage and UI triggering run concurrently
   - **Non-blocking**: Each consumer processes at its own pace
   - **Extensible**: New consumers can subscribe without changing existing code

**Performance Benefits**:
- Annotator loop never blocks on network calls (Nebula API)
- Nebula storage failures don't impact UI responsiveness
- UI updates happen immediately without waiting for memory storage
- Easy to add new consumers (e.g., analytics, logging, webhooks)

### Producer-Consumer Pattern
- **Producer (High Speed)**: Captures events and screens immediately with throttling
  - Throttle interval: 500ms minimum between screen captures
  - Keystrokes accumulated as dots (`.`) or shortcut markers (`[SHORTCUT:cmd-tab]`)
  - Screen frames captured and buffered without caching
- **Consumer (AI Pace)**: Processes buffer every 3 seconds
  - Prevents blocking user interactions
  - Batches multiple events for efficient AI processing
  - Clears keystroke buffer after consumption (but keeps screen as baseline)
- **Fan-Out (Parallel Consumers)**: Broadcasts annotations via AsyncStream
  - Nebula consumer stores to memory service
  - Execution agent evaluates and triggers UI
  - Both run concurrently without blocking each other

### Async Patterns
- `ScreenCaptureService.captureActiveScreen()` uses Swift async/await with ScreenCaptureKit
- `AnnotatorService.annotate()` bridges callback-based `GrokClient` to async via `withCheckedContinuation`
- `AppCoordinator` uses `Task {}` blocks for non-blocking coordinator methods that support optional self binding
- All buffer operations use Swift actors for thread-safe concurrent access

### Screen Capture Specifics
- Uses `OneShotFrameGrabber` (ScreenCaptureService.swift:53) that implements `SCStreamOutput`
- **No caching**: Each capture creates a new grabber instance for fresh frames
- `firstFrame()` uses checked continuation that resolves when first frame arrives
- Captures entire display at native resolution with BGRA pixel format
- Gets frontmost app name and window title via NSWorkspace

### Grok AI Integration
- **Annotator Model**: `grok-2-vision-1212` - Vision + language for understanding screen content
- **Executor Model**: `grok-4-fast` - Fast text model for suggestions and execution planning
- Uses OpenAI-compatible Chat Completions API format
- Image attachments via base64 data URLs: `data:image/png;base64,...`
- Structured prompts with few-shot examples for consistent JSON output
- **Actionable automation prompts** with 5 detailed examples of interactive AppleScript patterns

### AppleScript Execution Capabilities
The executor generates **interactive, actionable** AppleScripts that perform real UI automation:

1. **Keyboard Input**:
   ```applescript
   keystroke "text to type"
   keystroke "v" using command down  -- Paste
   keystroke return  -- Enter key
   ```

2. **Cursor & Clicking**:
   ```applescript
   click button "Submit" of window 1
   click at {500, 300}  -- Screen coordinates
   ```

3. **Clipboard Operations**:
   ```applescript
   keystroke "a" using command down  -- Select all
   keystroke "c" using command down  -- Copy
   keystroke "v" using command down  -- Paste
   ```

4. **Menu Navigation**:
   ```applescript
   click menu item "Format Document" of menu "Edit" of menu bar 1
   ```

5. **Multi-Step Workflows**:
   - Activate applications
   - Add delays for UI responsiveness (0.2-0.5s)
   - Chain multiple operations together
   - Switch between apps and paste content

The prompt includes task-specific patterns for Terminal, Code Editors, Browsers, Documentation, and Communication tasks.

### Memory Integration (Nebula API)
- **Base URL**: `https://api.nebulacloud.app`
- **Store Endpoint**: POST `/v1/memories`
  - Request: `NebulaMemoryRequest` with fields:
    - `content`: Full context string with task details, analysis, and activity
    - `metadata`: Dictionary of string key-value pairs (all values converted to strings)
    - `collection_ref`: Collection UUID
    - `engram_type`: Must be `"document"` or `"conversation"` (we use `"document"`)
  - All metadata values automatically converted to strings (numbers, bools, etc.)
  - Response: Contains `id` or `memory_id` on success

- **Search Endpoint**: POST `/v1/search`
  - Request: `NebulaSearchRequest` with fields:
    - `query`: Semantic search query string
    - `collection_ids`: Array of collection UUIDs to search
    - `limit`: Maximum number of results (default: 5)
  - Returns array of matching memories with content and metadata

- **Comprehensive Context Storage**:
  - Task identification (label, app, window)
  - AI analysis (summary, confidence score)
  - User activity (keystroke count, shortcuts detected, activity patterns)
  - Temporal data (annotation timestamp, buffer timestamp)
  - Metadata flags (has_shortcuts, keystroke_count, type="task_detection")

- **Search & Retrieval**:
  - Searches by task label for semantic similarity
  - Retrieves top 5 relevant memories
  - Used to inform Grok's execution planning with historical patterns
  - Execution plans also stored separately with type="execution_plan"

### Permission Management
- **Smart Permission Checking** (Permissions.swift:15):
  - Screen Recording: Uses `CGPreflightScreenCaptureAccess()` to check, `CGRequestScreenCaptureAccess()` to request
  - Accessibility: Uses `AXIsProcessTrusted()` for silent checks
  - **One-Time Prompt**: Only prompts for accessibility permission once (first launch)
  - Subsequent launches: Silent checks without prompting
  - Flag stored in UserDefaults: `"AccessibilityPromptShown"`
  - Combined with disabled code signing, permissions persist indefinitely in Debug mode

## macOS Permissions Required

The app requires these permissions to function:

### Required Permissions
1. **Screen Recording** (for ScreenCaptureKit capture)
   - Required to capture screen images for AI analysis
   - Requested automatically on first launch via `CGRequestScreenCaptureAccess()`
   
2. **Accessibility** (for CGEventTap keyboard monitoring and System Events automation)
   - Required for keystroke monitoring via CGEventTap
   - Required for AppleScript UI automation (clicking, typing, etc.)
   - Prompted only once on first launch
   - Subsequent launches check silently via `AXIsProcessTrusted()`
   
3. **Network access** (for Grok and Nebula API calls - automatic, no prompt)

### Permission Persistence
**Because Debug builds have code signing disabled** and the build location is fixed:
- Grant permissions once after first build
- **Permissions persist across all rebuilds** (no re-prompting)
- Only need to re-grant if you manually revoke in System Settings
- This is a huge developer experience improvement

### First-Time Setup
After building the app for the first time, grant permissions:

1. **Run the app:**
   ```bash
   open build/Debug/neb-screen-keys.app
   ```

2. **Screen Recording** will prompt automatically - click "Allow"

3. **Accessibility** will prompt automatically - click "Open System Settings"
   - In System Settings → Privacy & Security → Accessibility
   - Toggle ON for `neb-screen-keys`

4. **That's it!** These permissions will persist across rebuilds.

**Note**: The app checks permissions on launch but only prompts once. Logs will show permission status:
```
[System] Screen Recording permission not granted; capture will fail.
[System] Accessibility permission not granted; keystroke monitoring and automation will fail.
```

If you see these warnings, grant the permissions in System Settings manually.

## Common Issues & Debugging

### Issue: Nebula Returns 401 Unauthorized
**Symptoms:**
```
[Nebula] HTTP 401
[Nebula] Error body: {"error":"Missing or invalid Authorization header"}
```

**Solution:**
- Check your `.env` file has correct `NEBULA_API_KEY`
- API key should start with `neb_` prefix
- Verify key is valid in your Nebula dashboard: https://app.nebulacloud.app

### Issue: Nebula Returns 422 Validation Error
**Symptoms:**
```
[Nebula] HTTP 422
[Nebula] Error body: {"error":"Validation error: ..."}
```

**Common Causes:**
1. Wrong `engram_type` - Must be `"document"` or `"conversation"` (we use `"document"`)
2. Wrong field names - Must use `collection_ref` not `collection_id`
3. Non-string metadata values - All metadata must be string key-value pairs

**Current Implementation**: All these are correctly handled in `NebulaClient.swift`

### Issue: Grok Returns 404 Model Not Found
**Symptoms:**
```
[Annotator] API Response Status: 404
[Annotator] API Error Response: {"error":"The model grok-beta was deprecated..."}
```

**Solution:**
- Update to current Grok models
- Vision: `grok-2-vision-1212`
- Text: `grok-4-fast` or `grok-2-1212`

**Current Implementation**: Already using correct models

### Issue: Screen Capture Shows Old/Stale Images
**Solution:** Fixed - `OneShotFrameGrabber` no longer caches images. Each capture is fresh.

### Issue: Huge Black Spaces in Logs
**Solution:** Fixed - Base64 images and large JSON payloads are now truncated in logs, only summaries shown.

## Testing Strategy

- **neb-screen-keysTests**: Unit tests for core logic
- **neb-screen-keysUITests**: UI automation tests for overlay interactions

## Recent Improvements & Changes

### December 2024 Updates

#### 1. Fan-Out Architecture with Annotation Buffer (Latest)
- **Decoupled Consumers**: Introduced `AnnotationBufferService` actor for multicast streaming
- **Parallel Processing**: Nebula storage and Execution Agent now run concurrently
- **Non-Blocking Annotator**: AI loop never waits for network calls or UI updates
- **AsyncStream-Based**: Each consumer gets independent stream subscription
- **Extensible Design**: Easy to add new consumers (analytics, webhooks, etc.) without modifying existing code
- **New Services**:
  - `AnnotationBufferService` (Models.swift:56): Actor-based multicast buffer
  - `ExecutionAgent` (ExecutionAgent.swift:9): Dedicated service for task evaluation and UI triggering
- **Performance Improvements**:
  - Nebula API failures don't block UI responsiveness
  - UI updates happen immediately without waiting for memory storage
  - Better separation of concerns and testability

#### 2. Enhanced HTTP Status Handling
- **Accept All 2xx Codes**: Changed from checking `== 200` to accepting `200...299` range
- **202 Accepted Support**: Nebula's async processing now properly handled
- **Special Logging**: 202 responses get success message: "✅ Memory queued successfully (Async processing)"
- **No False Alarms**: Eliminated incorrect error logs for valid 2xx responses

#### 3. Comprehensive Context Flow (Annotator → Nebula → Executor)
- **Full Information Pipeline**: All curated information from Grok Annotator is now stored in Nebula and retrieved by Executor
- **Enhanced Storage**: Now stores task details, AI analysis, keystroke patterns, shortcuts detected, confidence scores, and timestamps
- **Rich Executor Prompts**: Executor receives comprehensive context including current task, user activity signals, and historical patterns
- **Metadata Conversion**: Automatic conversion of all metadata values to strings for API compatibility

#### 4. Actionable UI Automation
- **Interactive AppleScript**: Executor generates scripts that perform real UI interactions
- **System Events Integration**: Uses macOS System Events for keyboard input, mouse clicks, clipboard operations
- **5 Comprehensive Examples**: Prompt includes detailed examples for Terminal commands, code formatting, copy/paste, menu navigation, and multi-step workflows
- **Task-Specific Patterns**: Guidance for different task types (Terminal, Code Editor, Browser, Documentation, Communication)
- **Safety Guidelines**: Explicit instructions to avoid destructive actions, use proper delays, and be specific to detected context

#### 5. Smart Overlay System
- **AI-Generated Suggestions**: Cursor-side panel shows specific, actionable suggestions before execution
- **Dynamic Updates**: Shows "Thinking..." initially, then updates with Grok's suggestion
- **Preview Format**: "Type and run 'brew restart postgresql'" instead of generic "Can help with debugging"
- **Enhanced Decision Panel**: Shows task label with clearer buttons ("Yes, Execute" / "Not Now")
- **Multi-line Support**: Both panels support text wrapping for longer descriptions

#### 6. Permission Persistence Fix
- **Disabled Code Signing**: Debug builds no longer use automatic code signing
- **One-Time Prompts**: Accessibility permission only prompted once (first launch)
- **Silent Checks**: Subsequent launches check permissions without prompting users
- **Build Consistency**: Same code signature across rebuilds = permissions persist
- **Better UX**: No more repeated permission dialogs on every rebuild

#### 5. Nebula API Integration (Per Official Docs)
- **Correct Endpoints**: Using `https://api.nebulacloud.app/v1/memories` and `/v1/search`
- **Type-Safe Structs**: `NebulaMemoryRequest`, `NebulaSearchRequest`, `NebulaMemoryResponse`
- **Proper Field Names**: `collection_ref` (not `collection_id`), `engram_type` ("document" or "conversation")
- **String Metadata**: All metadata values converted to strings automatically
- **Error Handling**: Proper HTTP status checking and JSON-RPC error handling
- **Comprehensive Logging**: Request/response logging without massive payloads

#### 6. Clean Logging System
- **No Emojis**: Removed all emoji characters from logs for professional output
- **Smart Truncation**: Base64 images and large JSON payloads logged as summaries only
- **Readable Format**: `[HH:mm:ss.SSS] [Category] message`
- **Categorized**: Event, Buffer, Annotator, Executor, Nebula, Flow, Capture, System
- **Debug-Friendly**: Shows HTTP status codes, payload sizes, but not 500KB+ base64 strings

#### 7. Bug Fixes
- **Screen Capture Caching**: Fixed `OneShotFrameGrabber` caching first image - now captures fresh frames every time
- **Grok Model Deprecation**: Updated from deprecated `grok-beta` to `grok-4-fast` and `grok-2-vision-1212`
- **Nebula Validation**: Fixed 422 errors by using correct field names and engram_type values
- **False Success Logging**: Fixed logging "success" on HTTP 401/422 errors - now properly fails
- **HTTP Status Handling**: Now treats non-200/201 status codes as failures before attempting JSON parsing

## API Documentation References

- **Grok AI**: https://docs.x.ai/api (OpenAI-compatible Chat Completions API)
- **Nebula Memory**: https://docs.trynebula.ai/introduction (REST API with Codable structs)

## Development Tips

1. **Monitor Logs**: Use Console.app or terminal to watch real-time logs for debugging
2. **Check Environment**: Verify `.env` file is in `~/.config/neb-screen-keys/.env` with valid keys
3. **Rebuild Once**: After code changes, rebuild and permissions should persist
4. **Reset Permissions**: Delete app from System Settings and use `Permissions.resetPromptFlag()` to test first-run experience
5. **Nebula Testing**: Use curl to test Nebula API credentials independently before debugging app
