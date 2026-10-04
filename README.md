# SidecarBridge

<p align="center">
  <img src="Mac/Assets.xcassets/BrandMark.imageset/BrandMark.png" width="160" alt="SidecarBridge icon">
</p>

<p align="center">A secure remote window into your Mac, with iPhone, iPad, and Mac Viewer keyboard and pointer input.</p>

<p align="center">
  <a href="https://apps.apple.com/app/sidecarbridge/id6792298083">
    <img src="https://img.shields.io/badge/Mac%20App%20Store-Available-0A84FF?logo=apple&logoColor=white" alt="SidecarBridge Mac App Store release">
  </a>
  <img src="https://img.shields.io/badge/iOS%2FiPadOS-Available-34C759?logo=apple&logoColor=white" alt="SidecarBridge iOS and iPadOS release">
</p>

The App Store references above identify the author's SidecarBridge apps. They
are separate from this fork's ScreenDock Host and Viewer builds.

For the full architecture, protocol, permission, distribution, testing, and troubleshooting reference, see [SIDECARBRIDGE_TECHNICAL_GUIDE.md](SIDECARBRIDGE_TECHNICAL_GUIDE.md). The current accessibility support matrix is in [ACCESSIBILITY.md](ACCESSIBILITY.md).

This fork preserves SidecarBridge iPhone/iPad compatibility and adds encrypted
Mac-to-Mac viewing through ScreenDock Host and ScreenDock Viewer.

### ScreenDock Host and Viewer

The fork builds two macOS products: **ScreenDock Host** and **ScreenDock Viewer**. ScreenDock Viewer connects to a Mac running ScreenDock Host. Select the discovered Mac and tap **Connect**. For first-time pairing, enter the Mac's current 16-digit code; an optional private IPv4 address can be supplied with that code when Bonjour discovery is unavailable. The encrypted session carries the Mac screen, mouse and keyboard input, clipboard text, and verified file transfers. Both Macs need Local Network access, and the Mac being viewed still needs Screen Recording and Accessibility permission for capture and remote input. This is an in-app remote display stream; it does not create Apple's native extended Sidecar display.

ScreenDock Host remains compatible with the existing SidecarBridge iPhone and iPad apps. It advertises both the original SidecarBridge Bonjour services and ScreenDock's fork-specific services; the Viewer searches only for ScreenDock services. ScreenDock uses TCP port `45454` by default, the same port as the author app. It selects `45455` only when the original SidecarBridge Host is already running or port `45454` is occupied. ScreenDock has its own pairing-trust namespace, so pair each Viewer with a Mac once; that first pairing does not replace the SidecarBridge apps' saved trust.

The fork products are version `1.5` build `124`, with bundle identifiers `com.screendock.host` and `com.screendock.viewer` (Debug builds add `.debug`). The author-owned iPad target remains version `1.4` build `6` with its existing identity. Build ScreenDock Host with the `SidecarBridgeMac` scheme and ScreenDock Viewer with `SidecarBridgeViewerMac`; `SidecarBridgePad` remains the original iPad app target.

For safe removal of the ScreenDock apps and their current-user data, see [the uninstall guide](docs/UNINSTALL.md) and `scripts/uninstall-screendock.sh` (dry-run by default).

For safe removal of the original SidecarBridge macOS Host and Viewer apps, see [the original app uninstall guide](docs/UNINSTALL_SIDECARBRIDGE.md) and `scripts/uninstall-sidecarbridge.sh` (dry-run by default).

The author-owned `project.yml` and `SidecarBridge.xcodeproj` stay at their
upstream baseline. Fork builds use the additive `project.fork.yml` overlay and
the generated `SidecarBridgeFork.xcodeproj`; regenerate it before opening or
building the fork project:

```sh
./scripts/generate-fork-project.sh
open SidecarBridgeFork.xcodeproj
```

The Host and Viewer schemes generate the ScreenDock products from the fork
overlay. CI and release builds generate this fork project first and build only
the macOS apps; the author-owned project and iPad target retain their original
settings.

Text composition uses the Viewer Mac's active macOS input method; only committed
text is sent to the remote Mac. The Magic Keyboard 中/英 key toggles the remote
Mac's Chinese/English input source, and Control-Space cycles its input sources.

Use native macOS **Full Screen** (Control-Command-F, or the green window button)
for an edge-to-edge viewing area. Full screen hides Viewer controls. Use the
**View** menu's **Show ScreenDock Controls / Hide ScreenDock Controls** command
(Control-Command-H) to bring them back or hide them. Exiting full screen restores
the previous windowed layout and its saved control visibility. These shortcuts
stay local; plain Escape and other remote shortcuts still go to the host.

Successful pairing saves the trust credential in Keychain and remembers the
last authenticated Mac, including code-first/manual-IP connections. Temporary
codes are cleared, not saved. Select a **Saved** Mac and press **Connect** without
a code on later launches; discovery remains passive. A new code is needed if
the host resets/revokes pairing or the saved credential is no longer available.

#### Native Viewer tests (macOS only)

`MacViewerConnectionTests`, `MacViewerInputTests`, `MacViewerVideoTests`,
`MacViewerPresentationTests`, and `MacViewerRegressionTests` cover lifecycle/pairing, capability negotiation,
clipboard and preference isolation, mouse/keyboard routing, frame ordering,
bounded presentation queues, keyframe recovery, and ACKs after reconnect.
Presentation unit tests simulate full-screen notifications and cover local shortcuts,
saved control visibility, and hidden-window SwiftUI layout snapshots; changing
chrome must not replace the video/input views or restart the connection.
Run just these suites from the repository root:

```sh
./scripts/generate-fork-project.sh
xcodebuild -project SidecarBridgeFork.xcodeproj -scheme SidecarBridgeMac \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath .build/ViewerTests CODE_SIGNING_ALLOWED=NO \
  -only-testing:SidecarBridgeTests/MacViewerConnectionTests \
  -only-testing:SidecarBridgeTests/MacViewerInputTests \
  -only-testing:SidecarBridgeTests/MacViewerVideoTests \
  -only-testing:SidecarBridgeTests/MacViewerPresentationTests \
  -only-testing:SidecarBridgeTests/MacViewerRegressionTests test
```

Omit the five `-only-testing` options to run all macOS unit tests. These tests
use a fake transport, isolated defaults/pasteboards/directories, hidden AppKit
views, and synthetic video data; they do not connect to another Mac, post
system input events, access pairing credentials, or build the iPad target.
Video checks validate sample admission/presentation state, not decoded pixel
accuracy or physical display latency. Real two-Mac pairing, TCC permissions,
and end-to-end decoding/input still need manual acceptance testing.

The separate `SidecarBridgeViewerUI` scheme runs `MacViewerFullScreenUITests`
against the actual app and its secondary SwiftUI `Window`, not a hand-created
`NSWindow`. It clicks the native green button and the Viewer button, exercises
Control-Command-F, waits for real full-screen completion, checks screen-sized
geometry and windowed size restoration, and saves screenshots in the xcresult.
It does not override `toggleFullScreen` or post completion notifications.

```sh
./scripts/generate-fork-project.sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project SidecarBridgeFork.xcodeproj -scheme SidecarBridgeViewerUI \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath .build/ViewerUITests -parallel-testing-enabled NO \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= test
```

Before a local run, complete the `macos-ui-test-preflight` check and continue
only when it reports ready. This is an interactive desktop test: it requires an
unlocked graphical session and XCTest UI automation access, launches/terminates
the local test app, and temporarily switches Spaces. Do not run it during an
active remote session.
It never presses Connect, grants permissions, or runs the iPad target. Its local
ad-hoc signature is for testing only, not Developer ID distribution.

If the UI-test preflight is not ready, use this command to run CI without
launching the UI runner:

```sh
./.codex/ci.sh --skip-viewer-ui-tests
```

For a release check in the same state, pass `--skip-viewer-ui-tests` to
`scripts/release-macos.sh`. This skips only the UI suite and does not count as a
UI-test pass.

macOS build 111 keeps the Viewer trust credential across reconnects and adds a
confirmed per-Mac **Forget** action. Build 110 explicitly gives the Viewer a
principal window-manager role and enables native full screen on macOS 15+. The macOS 14 AppKit fallback also
removes the separate auxiliary-window role; forcing only `fullScreenPrimary`
or rebinding the green button does not address that role conflict. Full Screen
is available before connecting as well as during a session.

### Connection usability update (1.3)

The 1.3 release line includes code-first pairing (**Scan Mac Code → Connect**), a 16-digit field that accepts dashes, saved-device cards, steadier reconnects, improved keyboard/trackpad input, adaptive stream quality, and clearer transfer progress. See the [research, implementation, security boundaries, and verification notes](CONNECTION_USABILITY_RESEARCH.md), plus the [keyboard placement release](releases/1.3-ios19-keyboard-placement.md) and [storage/streaming optimization notes](releases/1.3-mac99-storage.md).

The latest uploaded builds are **iOS/iPadOS 1.4 (6)** and **macOS 1.4 (106)**. App Store Connect reports both as `VALID` and `IN_BETA_TESTING`; neither 1.4 binary has been submitted for App Review. The Mac pairing window shows a large QR code and grouped code with Copy Code feedback, while the iPad keeps the manual code path available when discovery is slow. The iPad 1.4 line adds an optional developer-only live frame-interpolation experiment, automatic decoder/keyframe recovery, a Picture in Picture background-video path, and a 30-second FPS history chart in Developer settings. See the [implementation and testing notes](FRAME_INTERPOLATION_AND_BACKGROUND.md), [iOS/iPadOS 1.4 (2) recovery record](releases/1.4-ios2-interpolation-recovery.md), and [iOS/iPadOS 1.4 (6) FPS history record](releases/1.4-ios6-fps-history.md).

### Apple Sidecar setup (local development)

On iPad, open **Settings → Apple Sidecar setup** (also available under **Other connection options**). Choose the USB or nearby-wireless checklist. If the apps are securely connected, **Open Displays on Mac** sends a setup request without stopping the app stream. You still select your iPad in Apple's Displays settings; this is not automatic native activation or an embedded native display. The Mac app has the same guide. Native Sidecar itself does not require the companion app. See [native route research, behaviour and tests](NATIVE_SIDECAR_SETUP.md).

### Optional connection without the Mac companion (in development)

The iOS/iPadOS dashboard includes **Mac Screen Sharing** under **Other connection options**, a VNC client for
macOS's built-in Screen Sharing server. It requires enabling VNC access on the
Mac, entering its local address and separate VNC password, and explicitly tapping
Connect. It controls the existing desktop; it is not native Sidecar or an
automatic USB connection. **Legacy VNC is unencrypted** and should only be used on
a trusted private network. The paired companion route retains encrypted streaming.
See [setup, controls, limitations, and test coverage](MAC_SCREEN_SHARING.md).
Included in the 1.3 iOS/iPadOS update. The paired encrypted route remains the
recommended connection; this optional mode is explicitly user-started and is
not native Apple Sidecar. See the [release record](releases/1.3-ios13.md).

## Windows companion

The Windows host is maintained on the separate [`windows` branch](https://github.com/yu314-coder/SidecarBridge/tree/windows).
It is a native Win32 C++ shell using WebView2 with the same public
SidecarBridge v3 LAN protocol used by the Apple clients. The host advertises
`_sb-direct._tcp`, accepts the iPad's 16-digit first pairing, stores the trusted
credential with Windows DPAPI, streams a bounded desktop JPEG, and translates
keyboard, modifier-click, pointer, scroll, clipboard, and acknowledged file
transfer messages. Read the branch's [`windows/README.md`](https://github.com/yu314-coder/SidecarBridge/blob/windows/windows/README.md)
for Windows build prerequisites and the runtime boundary. It is a local
display stream for iPad control, not Apple's private Sidecar virtual monitor.

## App Store

- **macOS:** [Download SidecarBridge from the Mac App Store](https://apps.apple.com/app/sidecarbridge/id6792298083)
- **iOS/iPadOS:** [Download SidecarBridge from the App Store](https://apps.apple.com/app/sidecarbridge/id6792298083)

The universal iOS/iPadOS app is available from the same multi-platform listing. The latest TestFlight binaries are iPadOS/iOS **1.4 (6)** and macOS **1.4 (106)**; both are Apple-processed `VALID` builds available to internal testers. The public App Store listing remains unchanged until a separate App Review submission is made. The prior 1.3 update includes refreshed descriptions and screenshots, the in-viewer and connection-screen file-transfer progress banner, iPad File Manager, foreground decoder reset, fresh ScreenCaptureKit capture-source rebuild, and keyframe recovery. The iPad 1.4 line adds bounded asynchronous VideoToolbox decoding, automatic fresh-IDR recovery, and a Developer-only FPS history chart for received/submitted frame rates alongside iPad refresh rate.

On macOS, optional **Shutdown Handoff** keeps an active remote-control session alive while other user apps close during logout, restart, or shutdown. If another app still needs attention, or the remote connection is lost, SidecarBridge cancels the termination request instead of disappearing and leaving the Mac uncontrollable. macOS limits graceful termination delays to under two minutes, so the hold is capped at 105 seconds.

Automatic startup uses the supported macOS Login Item service and therefore begins only after the user signs in. An App Store app cannot run its screen-capture and Accessibility-controlled remote session at the FileVault or macOS login window.

When either app starts, it uses this order:

1. Discover possible routes in the background, but wait for the user to tap Connect on iPhone or iPad.
2. Authenticate the selected Mac and request the encrypted in-app stream over a local-network or AWDL connection. This stays inside SidecarBridge and does not open Apple's Continuity/Sidecar screen.
3. If direct LAN is unavailable, retain Multipeer Connectivity as the nearby/peer-to-peer fallback.
4. On iPad only, offer **Apple Sidecar setup** separately. Opening its guide or requesting Displays settings does not start native Sidecar; the user must select the iPad in Apple's UI.

The connection screen is code-first but still user-initiated: scan the Mac QR or enter its 16-digit code (dashes accepted), then tap **Connect**. A discovered card is not required. The code authenticates a route; it is not itself a network address, so discovery remains passive and never connects just because a Mac was found. Saved Macs have their own Connect action after the first successful pairing.

The in-app stream first uses Network.framework Bonjour discovery across the local network and Apple peer-to-peer link technologies. It immediately retries the last successful private Mac address while discovery runs, and starts Multipeer Connectivity as a nearby fallback after 0.75 seconds. Every route performs ephemeral Curve25519 key agreement and encrypts screen/input packets with direction-separated ChaChaPoly keys and replay-protected counters. A new device enters the Mac's rotating 16-digit, five-minute pairing code; both devices prove the secret with role-separated HMACs before any app data is accepted. Successful verification issues a random 256-bit trusted-device credential stored in the Data Protection Keychain, so later connections do not ask again. Encrypted heartbeats verify the active route every three seconds, show measured round-trip latency in both apps, and rebuild stale sessions automatically. It is intentionally local/nearby only; this project does not publish the Mac screen to the public Internet or require an Internet connection.

Both endpoints must support the same secure protocol; matching build numbers are not required. Incompatible protocol versions are rejected rather than downgraded to insecure transport. Existing pre-migration credentials are copied from the legacy Keychain into the protected Keychain on first read. An unauthenticated rejection does not erase trust. Entering the Mac's current code explicitly repairs stale pairing and replaces the credential only after successful verification.

## Build and install

Requirements: Xcode 16 or newer, XcodeGen 2.46.0, macOS 14+, and iOS/iPadOS 17+.

```sh
./scripts/generate-fork-project.sh
open SidecarBridgeFork.xcodeproj
```

In Xcode:

1. Select the `SidecarBridgeMac` target, choose your Apple development team, then run it on **My Mac**.
2. Select `SidecarBridgePad`, choose the same or another valid development team, then run it on an iPhone or iPad.
3. Accept **Local Network** on both devices.
4. For first-time pairing, scan the Mac's QR code or enter its 16-digit one-time code, then tap Connect. ScreenDock Host mutually authenticates LAN and nearby P2P and saves a device-specific Keychain credential for later connections.
5. If the fallback is needed, grant **Screen Recording** to ScreenDock Host on the Mac, quit it, and reopen it.

For automatic startup, use the **Automatic startup** card in the Mac app. It distinguishes enabled, disabled, and macOS-approval-required states. If the app was moved or rebuilt after startup was enabled, click **Repair** once so the Login Item points at the currently installed app instead of an old Xcode build.

For reliable native Sidecar, both devices should use the same Apple Account with two-factor authentication. Wireless Sidecar also needs Wi-Fi, Bluetooth, and Handoff; USB Sidecar needs the iPad to trust the Mac.

The in-app direct stream does not use a raw USB socket. A cable can help only when macOS exposes a network route or when the user explicitly starts Apple's separate native Sidecar session; it does not make the SidecarBridge LAN listener reachable by itself. The app therefore reports a cable-only failure as a transport/route issue rather than treating the cable as proof of authentication.

If the app reports `NoAuth`, macOS or iOS/iPadOS has denied Local Network access. Use the app's **Allow Local Network** button and enable SidecarBridge in the system privacy page. Bonjour discovery cannot operate until this Apple-controlled permission is granted.

### iPhone support

The current mobile target is universal (`TARGETED_DEVICE_FAMILY = 1,2`). iPhone provides the encrypted in-app display, touch input, discovery, settings, file transfer, zoom, and background Picture in Picture controls. Apple System Sidecar is an iPad-only feature, so SidecarBridge hides that mode on iPhone instead of presenting a control that cannot work.

## What is and is not possible

Apple's native Sidecar stream has no supported third-party embedding API. iPadOS presents it through Apple's separate Sidecar system app and suspends the native session when the user switches to another iPad app. SidecarBridge keeps **In-App Display** separate from **Apple Sidecar setup**.

No documented third-party API for starting a Sidecar session was found in the reviewed Apple documentation or public AppKit/UIKit SDK headers. The App Store build uses NSWorkspace to request Apple's settings UI and never loads private Sidecar frameworks. The Displays deep link is best-effort, with a Settings-app fallback and manual instructions.

The code automatically falls back instead of trying to bypass iPadOS security:

- `SidecarConnector` opens Apple's public Displays settings UI.
- `ScreenStreamer` uses Apple's public ScreenCaptureKit API.
- `MacLANService` and `PadLANService` use Bonjour plus Network.framework so the paired apps can connect on the same Wi-Fi even if Apple's Sidecar device list is empty. If a router filters Bonjour multicast, the iPad first retries the last successful private Mac address and then performs a bounded private-`/24` probe for SidecarBridge's fixed encrypted port `45454`.
- The two apps use an encrypted Multipeer Connectivity session and remember each approved iPhone or iPad by its stable app device identifier for automatic reconnection.

The fallback is a hardware-encoded H.264 HiDPI stream with selectable **Adaptive**, **1080p**, **2K**, or **4K** quality and frame-rate targets. Adaptive targets at least 1080p when the source display supports it and chooses the highest practical local size; the explicit 4K target can request up to 3840 pixels. Direct local links can use up to 4K when the Mac display and viewer allow it. Nearby P2P uses up to 2K at a 60-FPS target, or an explicit 4K request at 60 FPS, while higher-cadence nearby sessions use a smaller resolution cap to protect latency. Bitrate scales with the selected pixel count and cadence (up to 48 Mbps direct and 36 Mbps nearby), and bounded queues shed stale work before the stream becomes seconds behind. When macOS reports warning or critical memory pressure, the Mac temporarily caps capture at 1920 or 1280 pixels and lowers bitrate; the saved quality target is restored when pressure clears. The Mac clamps the requested size to the source display, viewer capability, transport, and current memory profile. The iPad decoder keeps a short live-edge queue and requests an immediate keyframe after a gap or decoder reset. It mirrors the main display rather than creating a true extra macOS display. Native Sidecar remains the preferred path for a true virtual Retina display, native Apple Pencil behavior, audio, and extended-desktop support.

Closing the Mac window leaves SidecarBridge available as a background app and in the menu bar so an iPad can reconnect. The menu-bar menu exposes one-click stream start/stop, multi-file sending, the transfer folder, diagnostics, display settings, and the connection state without reopening the main window. On iPadOS, the live stream can be presented in the system Picture in Picture viewer when supported. The iPad target now declares the UIKit scene manifest required by iPadOS 27 and arms automatic PiP before the scene resigns active; the actual background callback only performs one guarded transition, avoiding duplicate PiP/reconnect races. SidecarBridge is a silent screen viewer and does not declare or provide persistent background audio. An eight-second PiP watchdog clears stuck starts and retries them only while the app is active. Background/resume retention no longer deliberately drops to 2 or 15 FPS: the capture and encoder keep a 60-FPS target in active, pressure, and background/PiP modes, while smaller pressure surfaces and bounded byte queues shed stale work if the route is congested. On return, the Mac now rebuilds its ScreenCaptureKit stream, drains callbacks from the old source, preserves packet sequencing, and sends a fresh IDR before resuming normal delivery; the iPad verifies the encrypted session, resets its decoder/presentation timeline, and gates display delivery until that IDR arrives. If PiP is unavailable, disabled, or closed, SidecarBridge only has iPadOS's short background-task grace period; no ordinary iPad app can run indefinitely outside an Apple-approved background mode. The 60-FPS policy is a software target, not a physical guarantee against a saturated link, display refresh limit, thermal throttle, or iPadOS suspension.

### Magic Keyboard and trackpad

Apple supports typing with a Smart Keyboard or Magic Keyboard connected to the iPad during native Sidecar, but specifies a mouse or trackpad connected to the **Mac** (or Apple Pencil on iPad) for pointing. SidecarBridge defaults to **Use app stream for Magic Keyboard + trackpad** and forwards:

- 120 Hz-capable trackpad hover/pointer movement, immediate left-button down/up, press-and-hold, double-click, right click, click-and-drag, phase-aware continuous trackpad scrolling, mouse-wheel scrolling, and two-finger touch scrolling;
- immediate one-finger cursor movement, tap/double-tap clicks, hold-then-drag, plus separate Apple Pencil taps and drag input;
- text, arrows, Return, Tab, Escape, Delete, and common Command shortcuts.

The input pipeline preserves Option, Shift, and Option–Shift modifier flags across pointer down, drag, and release events, so modifier-click workflows such as opening a link in a new tab or extending a selection behave like a local trackpad. Shortcuts are sent from the iPad's connected keyboard or trackpad input; the Mac interface does not add a separate shortcut palette. macOS requires the user to authorize SidecarBridge in **System Settings → Privacy & Security → Accessibility** before remote input can be injected.

Remote input requires macOS's permission to post events for SidecarBridge. macOS does not allow an app to add or authorize itself. In the Mac app, click **Allow Remote Input** and accept the native prompt; if macOS opens **Privacy & Security → Accessibility**, click `+` and select SidecarBridge (use **Show App** if needed). The app checks the dedicated PostEvent grant separately from optional Accessibility text insertion, because Apple treats those as separate TCC services. Input events are accepted only through the already encrypted, paired app session.

The iPad viewer forwards a trackpad or mouse primary button-down immediately, keeps it down for stationary long presses, and releases it only when the physical button is released. It captures UIKit's original physical-button mask and precise pointer location, rejects ambiguous button chords instead of guessing, and excludes drags or long holds from the next double-click sequence. A second valid nearby click carries macOS click-state 2 for a true double-click. Secondary clicks remain right clicks. The right-edge viewer drawer also exposes clearly labeled **Left**, **Double**, and **Right** buttons that act at the current Mac pointer position.

Continuous pointer, drag, and scroll samples are coalesced before encrypted transmission: when the link is busy, SidecarBridge keeps the newest cursor/drag location and accumulated scroll distance instead of queueing stale motion. Button-down, button-up, click, scroll begin/end, and keyboard events remain ordered barriers. This keeps control responsive during momentary Wi-Fi or peer-to-peer congestion without losing press-and-hold state.

Finger input does not share the delayed tap recognizers used by Apple Pencil. Touch-down leaves the Mac cursor where it is, and one-finger movement sends relative deltas so the finger behaves like a trackpad instead of teleporting the cursor beneath the touch. Touch-up clicks at the current cursor when the finger stayed within the tap tolerance. A second nearby tap carries macOS click-state 2 without delaying the first click. Holding still for 0.22 seconds starts a drag at the current cursor, then relative movement drags until release. Adding a second or third finger cancels the one-finger pointer gesture so scrolling, zooming, and viewport panning do not create accidental clicks.

### Viewer zoom and file transfer

- Move one finger to position the Mac cursor; tap to click, double-tap to double-click, or hold briefly and then move to drag.
- Swipe with two fingers to scroll the remote Mac.
- Pinch with two fingers to zoom the viewer from 100% to 400%.
- Drag with three fingers to pan while zoomed. Pointer and click coordinates are translated through the zoom so they continue to target the visible Mac content.
- Use the right-edge drawer's zoom buttons to step in, step out, or reset to 100%.

Files can move in either direction over the active encrypted same-Wi-Fi/AWDL or nearby P2P session. Transfers use 48 KB acknowledged chunks so the JSON/base64/encrypted packet stays within MultipeerConnectivity's reliable-message budget, preserve video/input responsiveness, and are limited to 512 MB. The Mac and iPad can queue multiple selected or dropped files, cancel the active transfer, and show live byte progress, transfer rate, and ETA. During a live viewer session and on the connection dashboard, the iPad shows an in-screen **Receiving from Mac** or **Sending to Mac** top bar with the filename, progress, and a shortcut to the file manager. A completed transfer is exposed only after its SHA-256 digest is verified and its hidden partial file is atomically renamed. Files received by the Mac are saved in the app's private `Application Support/SidecarBridge/Transfers` folder; files received by the iPad are saved under `Files > On My iPad > SidecarBridge > SidecarBridge Transfers`, listed in the iPad **File Manager** with refresh, share, and delete actions, and can also be exported with **Share Received**. An idle transfer now has a 45-second recovery window so slower local links are not canceled prematurely.

Clipboard sync is an explicit opt-in while the encrypted session is connected: the **Automatic text and file sync** toggle is off for new and upgraded installs so iPadOS does not repeatedly show paste-privacy prompts over the live viewer. When enabled, copy on either device can transfer without pressing a send button. A copied text value uses the bounded control message; files copied in Finder/Files use the verified file-transfer engine and are placed on the receiving device's clipboard after the digest is verified. The toggle does not disable the manual **Send Clipboard** and **Receive Clipboard** buttons. Connection baselines and content signatures prevent a remote write from being echoed back. macOS observes pasteboard notifications while the menu-bar app remains alive; iPadOS uses change notifications while active and reconciles a missed change when it returns. The monitor does not poll or read pasteboard contents during an H.264 stream, background transition, or launch, keeping clipboard permission work off the video cadence. If iPadOS fully suspends the app, the latest clipboard is reconciled as soon as the app returns because third-party iPadOS apps cannot run an unrestricted clipboard watcher while suspended.

### System information and diagnostics

Both apps show local system information including OS version, hardware model, architecture, active CPU cores, memory, available storage, thermal state, Low Power Mode, uptime, and SidecarBridge version/build. After authentication, each device exchanges its bounded snapshot through the existing encrypted control channel so the iPhone or iPad can show the connected Mac and the Mac can show the connected mobile device.

The iPhone/iPad detail sheet also shows the current route, heartbeat latency, decoded stream dimensions and frame rate, input acknowledgement latency, and Picture in Picture state. It remains available from the right-edge viewer drawer while streaming. **Copy Diagnostic Report** produces a support-ready text report that excludes pairing codes, credentials, stable device identifiers, IP addresses, and file paths.

## Research

- [Apple: Use your iPad as a second display for your Mac](https://support.apple.com/guide/mac-help/use-your-ipad-as-a-second-display-mchlf3c6f7ae/mac)
- [Apple: Sidecar system requirements](https://support.apple.com/102597)
- [Apple: Capturing screen content in macOS](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos)
- [Apple: Multipeer Connectivity](https://developer.apple.com/documentation/multipeerconnectivity)
- [Apple: Local network privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)
- [Apple: Handle trackpad and mouse input](https://developer.apple.com/videos/play/wwdc2020/10094/)
- [Apple: Track scroll events with `allowedScrollTypesMask`](https://developer.apple.com/documentation/uikit/uipangesturerecognizer/allowedscrolltypesmask)
- [Apple: Implement a continuous gesture recognizer](https://developer.apple.com/documentation/uikit/implementing-a-continuous-gesture-recognizer)
- [Ocasio-J/SidecarLauncher](https://github.com/Ocasio-J/SidecarLauncher) — demonstrated the private SidecarCore selectors and wired transport value; MIT-licensed, but explicitly subject to breakage after macOS updates.

## Security notes

- Multipeer Connectivity encryption is required, and SidecarBridge adds its own authenticated, replay-protected application encryption because transport encryption alone does not authenticate a device.
- Direct-LAN file chunks use the same Curve25519/HKDF/ChaChaPoly session as display and input packets.
- First pairing uses a random 16-digit code with about 53 bits of entropy and a five-minute lifetime. Role-separated client and server HMAC proofs bind the mobile identity, Mac identity, random nonce, and transport channel binding, so encryption is not mistaken for peer identity and captured proofs cannot be replayed.
- Successful pairing replaces the temporary code with a random 256-bit credential stored in both devices' Data Protection Keychains. The credential is proved—not transmitted—on later connections. Five failed attempts from one device, or twenty globally, within one minute trigger a temporary lockout.
- The Mac stores the device kind, display name, authorization time, and last-seen date locally. App relaunches and updates retain authorization; **Forget All** deletes every trusted-device credential and rotates the code.
- Nearby Multipeer Connectivity requires Apple's encrypted session plus the same mutual Keychain credential proof as direct LAN. Control, screen, and file packets are ignored until that proof succeeds.
- Public-Internet streaming would need authenticated identities, certificate pinning, a relay/VPN path, and stronger session authorization; it is deliberately outside this MVP.
