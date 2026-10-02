# macOS Dual-Mac Acceptance

This manual acceptance supplements `.codex/ci.sh`. Automated tests run on one
Mac and cannot verify real Bonjour discovery, macOS privacy prompts, cross-Mac
input methods, or sleep/wake behavior.

## Setup

- Intel Mac runs the SidecarBridge Host.
- M5 Mac runs the standalone SidecarBridge Viewer.
- Both use the release under test and are on the same local network.
- Record the version, build, Git revision, dirty-tree state, test result bundles,
  notarization submission IDs/status, and ZIP SHA-256 values from
  `.build/Release<build>/provenance.json`.
- Grant Screen Recording and Accessibility to the Host when prompted. Grant
  Local Network access to both apps.

## Checks

1. **Discovery and stable identity**
   - Confirm the Viewer lists paired online Macs, paired offline Macs, and
     currently discovered Macs separately.
   - Rename one Host, then refresh discovery. Confirm the saved route remains
     attached to its stable ID.
   - If two Hosts have the same display name, confirm their identity suffixes
     differ and connecting to one never authenticates the other.
   - Confirm the Viewer identifies its own Host as “This Mac” and disables
     connecting to itself.

2. **Forget and pair again**
   - On the Viewer, Forget one paired Host. Confirm only that route disappears
     from the paired list.
   - Wait for Bonjour discovery. Confirm it returns under “Currently
     discovered,” then connect with the Host's current one-time code.
   - Confirm the route returns under “Paired” after authenticated pairing and
     reconnecting does not ask for another code.

3. **Changing video and truthful health status**
   - Connect and observe the incoming frame rate, frames submitted to
     AVFoundation, and visible pixel-change rate.
   - Move windows and play a changing video on the Host. Confirm visible
     changes continue to register on macOS 14.4 or later.
   - On macOS 14.0–14.3, confirm the Viewer explicitly reports that visible
     pixel tracking is unavailable; received or queued frames must not be
     described as confirmed display output.
   - Pause the Host's changing content, then resume it. Confirm the Viewer
     reports unchanged output or requests video recovery when progress stalls,
     and that Refresh video restores changing output without forgetting the
     pairing.

4. **Sleep and reconnect**
   - Keep the Viewer connected, sleep the Host for at least 30 seconds, then
     wake it.
   - Confirm the connection health recovers and changing video resumes within
     90 seconds. If it does not, record the displayed error, transport, and
     whether a manual reconnect succeeds.

5. **Real input methods**
   - In a text editor on the Host, switch between English and a Chinese input
     method from the Viewer keyboard.
   - Type, commit Chinese text, move the pointer, click, scroll, and use
     keyboard shortcuts. Confirm the active input source and text remain
     correct on the Host.

## Record

For each check, record pass/fail, macOS versions, Host architecture, network
type, relevant privacy grants, and concise evidence. Attach screenshots or a
short screen recording for failures and keep those files outside the app bundle.
