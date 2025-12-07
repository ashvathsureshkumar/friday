# Fix: Permission Prompts on Every Rebuild

## The Problem

macOS tracks app permissions by **bundle identifier + code signature**. When you rebuild the app:
- The bundle stays the same: `showertracker.neb-screen-keys`
- BUT the code signature changes (because it's ad-hoc signed on each build)
- macOS sees this as a "different app" and asks for permissions again

## Solution: Disable Code Signing for Development

### Option 1: Disable Code Signing in Xcode (Recommended for Development)

1. Open `neb-screen-keys.xcodeproj` in Xcode
2. Select the project in the navigator
3. Select the `neb-screen-keys` target
4. Go to "Signing & Capabilities" tab
5. **Uncheck** "Automatically manage signing"
6. Set "Signing Certificate" to **"Sign to Run Locally"** (or "Development")

### Option 2: Modify project.pbxproj Directly

Edit the file: `neb-screen-keys.xcodeproj/project.pbxproj`

Find the Debug configuration (around line 390) and change:

```
CODE_SIGN_STYLE = Automatic;
```

To:

```
CODE_SIGN_IDENTITY = "-";
CODE_SIGN_STYLE = Manual;
```

Do the same for the Release configuration (around line 424).

### Option 3: Use xcodebuild with Signing Disabled

When building from command line:

```bash
xcodebuild -project neb-screen-keys.xcodeproj \
  -scheme neb-screen-keys \
  -configuration Debug \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  build
```

## Why This Works

When code signing is disabled:
- The app still runs locally
- The signature becomes consistent (or absent)
- macOS recognizes it as the "same app" across rebuilds
- Permissions are preserved between builds

## Important Notes

⚠️ **For Distribution:** You MUST re-enable code signing before distributing the app

✅ **For Development:** Disabling code signing is fine and actually recommended

## Verify It Works

After disabling code signing:

1. Clean build: `rm -rf build/`
2. Build: `xcodebuild -project neb-screen-keys.xcodeproj -scheme neb-screen-keys -configuration Debug CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO build`
3. Run: `open build/Debug/neb-screen-keys.app`
4. Grant permissions (one time)
5. Quit app
6. Rebuild: (same command as step 2)
7. Run again: `open build/Debug/neb-screen-keys.app`
8. **Permissions should NOT be asked again!** ✅

## Current Build Location

The app is correctly configured to build to:
- Debug: `build/Debug/neb-screen-keys.app`
- Release: `build/Release/neb-screen-keys.app`

This fixed location is already set via `CONFIGURATION_BUILD_DIR`.

## Alternative: Accept Permission Re-prompts During Development

If you prefer to keep code signing enabled during development:
- Permissions will be asked after every rebuild
- This is annoying but doesn't break anything
- Just click "Allow" each time
- Once you're done developing, build a signed Release version for daily use

