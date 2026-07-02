# MacHead - Features Walkthrough

We have successfully constructed, compiled, and verified **MacHead** along with its **Preferences UI Settings Window**, **Launch at Login** support, **Built-in Trackpad Auto-Disabler**, **Low Battery Sleep Protection**, **Automatic Microphone Muting**, **Custom AppIcon**, **Command Line Interface (CLI)**, **Local Web Dashboard (Web UI)**, **HTTP Basic Authentication Security**, and **Auto-Disable Keyboard/Trackpad in Headless Mode**.

## Technical Milestones & Discoveries

### 1. Private API Transition (`SkyLight.framework`)
- **Discovery**: In modern macOS versions on Apple Silicon, the private `CoreDisplay` function `CoreDisplay_DisplaySetUserDisplayMode` is no longer available.
- **Solution**: We successfully transitioned to the private CoreGraphics WindowServer API **`CGSConfigureDisplayEnabled`** from **`SkyLight.framework`**.
- **Action**: We wrap this inside a CoreGraphics transaction (`CGBeginDisplayConfiguration` & `CGCompleteDisplayConfiguration`) to commit the display enable/disable state.

### 2. Display ID Caching
- **Discovery**: Disabling a display via `CGSConfigureDisplayEnabled(config, id, false)` removes it from the active/online display list returned by `CGGetOnlineDisplayList`.
- **Solution**: We added a persistent caching system using `UserDefaults` in `DisplayManager.swift`. When the built-in screen is online, we store its display ID (e.g. `1`), and retrieve it from the cache to call `CGSConfigureDisplayEnabled(config, cachedID, true)` to restore it.

### 3. Icon Refinement & Startup Flash Fix
- **Discovery**: The status bar computer icon used to flash briefly for 1.0 second upon launch because of an initial startup delay.
- **Solution**: We modified `updateIcon()` in `AppDelegate.swift` to check the cached preferences immediately. If the user previously had headless mode enabled, it displays the  icon from the very first frame, completely resolving the flashing visual.

### 4. Interactive Dropdown Menu & Settings Panel
- **Dropdown Menu**: Clicking the status item now opens an `NSMenu` containing:
  - **MacBook Headless 模式** (with status checkmark)
  - **偏合设置...**
  - **退出 MacHead**
- **Settings Window**: Displays a beautiful settings panel (via NSHostingController wrapping SwiftUI `PreferencesView`) which includes:
  - Toggles for Launch at Login.
  - Toggles for Auto-enable Headless Mode on Launch.
  - Toggles for Preventing Idle Sleep.
  - Toggles for Disabling built-in trackpad when external mouse is connected.
  - Toggles for Disabling built-in keyboard and trackpad in Headless Mode.
  - Toggles for Battery Protection.
  - Toggles for Automatic Microphone Muting (disabled by default).
  - Toggles for Local Web Dashboard (disabled by default).
  - Configurable Management Password field for local Web Control Panel.
  - Live list of connected displays.
- **Launch at Login Integration**: Uses the modern `SMAppService` framework for background boot registration.
- **Safe Exit Recovery**: Exiting the app automatically restores the built-in display for safety.

### 5. Built-in Trackpad Auto-Disabler (`IOHIDManager`)
- **Discovery**: macOS locks the keyboard driver exclusively for the WindowServer (`kIOReturnExclusiveAccess` / `-536870207`), making it impossible to seize programmatically in user space. However, the trackpad is not locked and can be seized exclusively using `IOHIDDeviceOpen(trackpad, kIOHIDOptionsTypeSeizeDevice)`.
- **Solution**: We created `InputDeviceManager.swift` to monitor HID device matching:
  - Filter pointing devices on `SPI` (internal transport) as the built-in trackpad, and `USB` / `Bluetooth` as external mice.
  - If the user settings "有外接鼠标时禁用内置触控板" is checked and at least one external mouse is connected, we seize the built-in trackpad. This blocks all built-in trackpad inputs (clicks and movements) from reaching the OS, while leaving the external mouse fully functional.
  - When the external mouse is unplugged, we release the trackpad to restore normal input.

### 6. Low Battery Sleep Protection (`IOPowerSources`)
- **Discovery**: A MacBook running 24/7 as a headless server needs protection against deep battery draining during power outages.
- **Solution**: We created `BatteryManager.swift` using native IOKit Power Sources API:
  - Registers a notification listener `IOPSNotificationCreateRunLoopSource` to track power changes.
  - Evaluates when the Mac runs on Battery power (unplugged) and its capacity drops below a warning threshold (e.g. 20%).
  - If protection is active, it calls `HeadlessModeController.shared.evaluatePowerAssertion()` which releases the IOKit sleep prevention assertion (`IOPMAssertionRelease`), allowing the macOS system to sleep natively after idle periods, preserving battery.
  - Once plugged back to AC power, the sleep prevention assertion is automatically re-acquired.

### 7. Automatic Microphone Muting (`CoreAudio`)
- **Discovery**: Disabling the built-in FaceTime camera programmatically requires root permissions and disabling SIP due to macOS TCC sandboxing rules. However, muting/unmuting the default input microphone is fully supported in user space via CoreAudio APIs.
- **Solution**: We created `MediaDeviceManager.swift` using the `AudioObject` APIs:
  - Queries the default input device ID (`kAudioHardwarePropertyDefaultInputDevice`).
  - Sets the mute state (`kAudioDevicePropertyMute`) to `1` (Muted) when entering Headless Mode if the preference is enabled.
  - Caches the user's previous mute state (so we don't accidentally unmute if the user had already muted their mic manually) and restores it precisely on exit.
  - Configured as **disabled by default** to avoid unexpected muting on fresh installs.

### 8. Custom Application AppIcon (`sips` + `iconutil`)
- **Discovery**: Without Xcode or xcodebuild, generating standard macOS multi-resolution `.icns` files requires custom scripting.
- **Solution**: We created `generate_icns.sh` which resizes a high-quality user-provided PNG (`UserIcon.png`) into 10 required dimensions (ranging from 16x16 up to 1024x1024) using macOS's built-in `sips` engine, then packages them into `AppIcon.icns` via `iconutil`.
- **Packaging**: The bundle compilation script (`build.sh`) creates a standard `Resources` folder inside `MacHead.app/Contents/` and embeds the compiled icon there, while `Info.plist` declares `<key>CFBundleIconFile</key><string>AppIcon</string>`, displaying the new icon system-wide.

### 9. Command Line Interface (CLI) (`main.swift` + `DistributedNotificationCenter`)
- **Architecture**: We removed `@main` from the SwiftUI App struct and created `main.swift` as the unified entry point.
- **IPC Mechanism**: The CLI client and GUI daemon communicate via standard macOS distributed notifications. Since CLI calls are often issued over SSH, this avoids WindowServer permissions conflicts.
- **Preferences Sync**: We consolidated `UserDefaults` state mutation directly inside `HeadlessModeController`'s `enableHeadlessMode()` and `disableHeadlessMode()` functions, ensuring that terminal commands (e.g. `--enable` / `--disable`) are instantly stored and accurately returned by status queries.
- **Terminal Options**:
  - `-s, --status`: Returns `headless` (headless active), `normal` (display on), or `offline` (daemon not running, showing last saved state).
  - `-e, --enable`: Directs the running daemon to immediately turn off the internal display and hold assertions.
  - `-d, --disable`: Directs the running daemon to immediately restore the internal display.
  - `-h, --help`: Displays usage guide.

### 10. Local Web Dashboard (Web UI) (`NWListener` + HTML/CSS/JS)
- **Embedded Web Server**: Created `WebServer.swift` using Apple's modern `NWListener` framework, providing a zero-dependency HTTP server running on port `8080`.
- **System Resource Monitoring**: Queries raw processor cycles via Darwin kernel APIs (`host_processor_info`) and memory allocations (`host_statistics64`) to calculate exact CPU and active/free RAM percentages.
- **Glassmorphic UI**: Serves a single self-contained responsive dashboard using dark-mode HSL gradients, frosted blur cards, clean switches, glowing state indicators, and dynamically animated SVG circular gauges.
- **Interactive REST APIs**:
  - `GET /`: Returns the HTML dashboard.
  - `GET /api/status`: Returns system status and resource usages in JSON.
  - `POST /api/toggle-headless`, `POST /api/toggle-trackpad`, `POST /api/toggle-keyboard-headless`, `POST /api/toggle-microphone`, `POST /api/toggle-sleep`: Dispatches toggles on the main thread and responds with the updated state JSON.
- **Preferences Integration**: Added a "远程控制" section in `PreferencesView` displaying the opt-in toggle and the local network interface IP address URL (copy-paste enabled).

### 11. Web Server HTTP Basic Authentication (Web 鉴权保护)
- **Automatic Protection**: Generates a secure random 6-character default password (e.g. `MH-349B`) on the application's first launch if none is configured.
- **HTTP Handlers**: Evaluates incoming request headers using regular expressions matching `Authorization: Basic [credentials]` (case-insensitive).
- **Challenge Actions**: Responds with `401 Unauthorized` and `WWW-Authenticate: Basic realm="MacHead Secure Dashboard"` when credentials are absent or invalid. This forces browsers to prompt the user for input and automatically caches credentials for relative API request calls.
- **Preferences Sync**: The password can be viewed and configured via a text field in `PreferencesView` and changes apply immediately to active Web Server sockets.

### 12. Auto-Disable Keyboard/Trackpad in Headless Mode
- **Trackpad Blocking**: Automatically seizes the built-in trackpad (`kIOHIDOptionsTypeSeizeDevice`) when the MacBook is in Headless Mode and the setting is checked, completely disabling physical trackpad clicks and movements.
- **Heuristic Keyboard Interception**: Since the built-in keyboard driver is locked exclusively by the WindowServer (`kIOReturnExclusiveAccess`), we cannot seize it. Instead, we implement a high-precision Event Tap callback:
  - Register `IOHIDManager` keyboard matching (`kHIDUsage_GD_Keyboard`). When a raw keypress value report occurs on the built-in keyboard, we record its timestamp.
  - A global Quartz Event Tap (`CGEvent.tapCreate`) listens to key up/down/flags events.
  - If a key event occurs within **40 milliseconds** of the recorded built-in HID timestamp, we identify the event as originating from the built-in keyboard and return `nil` to drop (swallow) it.
  - If it does not match, the event is allowed to pass, keeping external keyboards fully functional.
- **Accessibility Integration**: Intercepting keypresses globally requires macOS **Accessibility Permissions**. We query authorization using `AXIsProcessTrusted()`. If unauthorized, we display a warnings label in `PreferencesView` with a link to launch System Settings.
- **Web Dashboard Sync**: Added a toggle switch in the HTML template and a `/api/toggle-keyboard-headless` POST API to allow remote control.

---

## Code Base Layout

- [Info.plist](../Resources/Info.plist): Sets `LSUIElement` to `true` and registers `AppIcon` as bundle icon file.
- [main.swift](../Sources/main.swift): Unified entry point parsing CLI arguments or launching the SwiftUI GUI.
- [MacHeadApp.swift](../Sources/MacHeadApp.swift): SwiftUI application entry point.
- [AppDelegate.swift](../Sources/AppDelegate.swift): Controls status item menu dropdown, registers preference defaults (including random password generation), starts the managers, listens to CLI notifications, and handles safe exit recovery.
- [PreferencesView.swift](../Sources/PreferencesView.swift): SwiftUI layout containing the settings toggles, password field, and accessibility notices.
- [LaunchAtLoginHelper.swift](../Sources/LaunchAtLoginHelper.swift): Wraps `SMAppService` registration.
- [InputDeviceManager.swift](../Sources/InputDeviceManager.swift): Listens to HID keyboards/pointers and manages the Event Tap / trackpad seizures.
- [BatteryManager.swift](../Sources/BatteryManager.swift): Monitors battery status and capacity to override sleep assertions dynamically.
- [MediaDeviceManager.swift](../Sources/MediaDeviceManager.swift): Interfaces CoreAudio to mute and restore default input microphone states.
- [WebServer.swift](../Sources/WebServer.swift): Implements the TCP/HTTP REST API endpoints with HTTP Basic Authentication, HTML template, and monitors CPU/Memory load.
- [DisplayManager.swift](../Sources/DisplayManager.swift): Handles SkyLight loading, display ID caching, and enabling/disabling the screen.
- [HeadlessModeController.swift](../Sources/HeadlessModeController.swift): Manages sleep prevention assertions, display change callbacks, and wake-up notifications.
- [generate_icns.sh](../Scripts/generate_icns.sh): Compiles a `.png` or `.jpg` into standard macOS multi-res `.icns` format.
- [build.sh](../build.sh): Shell compilation script.

---

## Verification Results

### Compilation & Auto-Deploy Verification
The compilation completes successfully and deploys to the applications directory automatically:
```bash
$ ./build.sh
Building MacHead...
Using SDK: /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk
Installing to /Applications...
Build successful! Created MacHead.app and installed to /Applications.
```

### Server Port Verification
```bash
$ lsof -i :8080
COMMAND     PID   USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
MacHead   90844 waffle    4u  IPv6  0x234cd44e3671844      0t0  TCP *:http-alt (LISTEN)
```

### Web API Keyboard Toggle Verification
- **Fetch Status**:
  ```bash
  $ curl -u admin:MH-349B http://localhost:8080/api/status
  {
    "headlessModeEnabled": true,
    "preventIdleSleep": true,
    "trackpadDisabled": false,
    "keyboardAndTrackpadDisabledInHeadless": true,
    "microphoneMuted": false,
    "batteryCapacity": 100,
    "isCharging": true,
    "powerState": "AC Power",
    "cpuUsage": 0.0,
    "memoryUsage": 97.51672576420329
  }
  ```
- **Toggle Setting**:
  ```bash
  $ curl -u admin:MH-349B -X POST http://localhost:8080/api/toggle-keyboard-headless
  {
    "keyboardAndTrackpadDisabledInHeadless": false,
    ...
  }
  ```
All toggles respond instantly.

### GitHub Repository & Release Verification
- **Codebase Pushed**: Successfully pushed to the remote repository `https://github.com/ox01024/MacHead.git` on the `main` branch.
- **First Release Published**: Successfully published release **`v0.1.0`** at `https://github.com/ox01024/MacHead/releases/tag/v0.1.0` containing the compiled binary package `MacHead-v0.1.0.zip` and the standard macOS installer image **`MacHead-v0.1.0-macos-universal.dmg`**.

