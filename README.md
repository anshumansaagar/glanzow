# Glanzow

Glanzow is a Mac menu bar app. It uses the Mac's camera to see which screen you are facing,
and moves keyboard focus to that screen before you start typing. Look at your other monitor
for a moment and the window you last used there comes to the front. It waits while you type or
use the mouse, so it never steals keystrokes mid-sentence.

Everything runs on the Mac. Camera frames are processed in memory and dropped; nothing is saved
to disk and the app makes no network calls at all.

The full requirements are in `requirements.pdf`. Code comments cite its requirement IDs
(`FR-FOC-01`, `NFR-04`, …), and every place where the spec was ambiguous carries a `// SPEC:`
comment explaining the choice.

## Requirements

- macOS 14 Sonoma or later, Apple silicon (Intel is best-effort)
- Xcode 15 or later (for the Swift toolchain and XCTest)
- A camera that can see your face: the built-in one, or any external webcam

## Build and run

```sh
make app      # build/Glanzow.app, release build, signed
make run      # build, then open it
make test     # unit tests (no camera needed)
make app CONFIG=debug   # debug build: adds pose recording to the debug pane
```

The project is a Swift package. `open Package.swift` opens it in Xcode for editing, but launch the
app with `make run`: the camera prompt and the Accessibility grant need a real `.app` bundle,
which `make app` assembles from the built executable plus `Resources/Info.plist`.

On first launch a four-step welcome window asks for camera access, then Accessibility, then runs
calibration. The green camera light stays on whenever Glanzow is tracking — that is expected.

## Signing

`make app` picks a signing identity automatically, in this order:

1. a **Developer ID Application** certificate (for distribution),
2. an **Apple Development** certificate (for your own Mac),
3. ad-hoc signing (`-`), as a last resort.

Use a real certificate. macOS ties the camera and Accessibility permissions to the app's code
signature. An ad-hoc signature changes on every build, so macOS forgets the permissions every
time you rebuild.

To choose an identity explicitly:

```sh
make app SIGN_ID="Developer ID Application: Your Name (TEAMID)"
```

The app runs with the hardened runtime and exactly one entitlement,
`com.apple.security.device.camera` (`Resources/Glanzow.entitlements`). It is **not** sandboxed:
the Accessibility APIs it needs to raise other apps' windows do not work inside the sandbox,
which is also why it can't ship on the Mac App Store.

## Notarization and the DMG

Notarization is Apple's malware scan for apps distributed outside the App Store. It needs a
Developer ID certificate and an app-specific password from appleid.apple.com.

Store the credentials once:

```sh
xcrun notarytool store-credentials glanzow-notary \
  --apple-id you@example.com --team-id TEAMID --password app-specific-password
```

Then build, sign, package, submit and staple in one step:

```sh
make notarize SIGN_ID="Developer ID Application: Your Name (TEAMID)"
```

The result is `build/Glanzow.dmg`. `make dmg` builds the DMG without notarizing it.

## Resetting permissions

To see onboarding again from scratch, or after changing the signing identity:

```sh
make reset-permissions
# which runs:
tccutil reset Camera dev.glanzow.Glanzow
tccutil reset Accessibility dev.glanzow.Glanzow
tccutil reset ListenEvent dev.glanzow.Glanzow   # Input Monitoring
defaults delete dev.glanzow.Glanzow             # optional: all settings, including "onboarding done"
```

Input Monitoring is only requested if macOS refuses the keyboard listener with Accessibility
alone.

## Where things are stored

| What | Where |
|---|---|
| Settings | `defaults read dev.glanzow.Glanzow` |
| Calibration | `~/Library/Application Support/Glanzow/calibration.json` |
| Switch log (for latency and false-switch review) | `~/Library/Application Support/Glanzow/events.jsonl` |
| Debug recordings | `~/Library/Application Support/Glanzow/Recordings/` |
| Live logs | `log stream --predicate 'subsystem == "dev.glanzow"'` |

The switch log and recordings hold numbers and display IDs only — never images.

## Tuning and debugging

- **Debug settings**: hold Option while the menu is open and choose *Debug Settings…*
  (debug builds always show the tab). It has the smoothing filter values, the off-screen
  threshold, pupil tracking, and the debug overlay.
- **Debug overlay**: live yaw and pitch, the distance to each display, the current decision,
  which guard is holding a switch back, and a dot on the screen Glanzow thinks you face.
- **Recording and replay**: in a debug build, *Start Recording* in the debug pane saves pose
  angles plus keystroke and mouse timestamps. Replay them through the same decision code with
  different settings, without sitting at the desk:

  ```sh
  make replay FILE=~/Library/Application\ Support/Glanzow/Recordings/pose-….json ARGS="--dwell 400 --head-turn 0.7"
  swift run ReplayCLI --help
  ```

## How it works

```
camera frames ──▶ PoseTracker ──▶ smoothed head pose ──▶ SwitchController ──▶ FocusManager
 (CameraCapture)   (Vision, One Euro)                    (dwell, guards)      (raise, warp)
                                    ▲                          ▲     ▲
                         DisplayClassifier          InputMonitor   WindowTracker
                         (calibrated models)        (typing/mouse) (last window per display)
```

1. **Calibration** records where your head points for each display while you follow a dot.
   Each display becomes a cluster of (yaw, pitch) angles.
2. **Classification** picks the nearest cluster for every frame (Mahalanobis distance). A pose
   far from every cluster is "off-screen" (phone, desk) and does nothing. Switching away from the
   current display needs a clear margin (the *Head turn needed* setting).
3. **Switching** happens only after the same display wins for the *Delay before switching* (300
   ms), and not while you type (3 s, unless you hold the turn for 1 s), use the mouse (1.5 s), have
   a menu, dialog, password field, screenshot tool or Mission Control open, or an excluded app is
   in front.
4. **Focus** goes to the window you last used on that display, else its frontmost window. The
   pointer follows, and a thin border flashes around the window.
5. **Learning**: each click nudges that display's calibration a little. If the clicks keep
   disagreeing with what Glanzow thought, it suggests recalibrating.

### Project layout

```
Glanzow/
  App/          menu bar, onboarding, settings, overlays, notifications (executable target)
  Tracking/     CameraCapture, PoseTracker, OneEuroFilter
  Calibration/  CalibrationStore, CalibrationOverlay, DisplayModel
  Decision/     DisplayClassifier, SwitchController
  System/       DisplayRegistry, InputMonitor, WindowTracker, FocusManager, AX, Hotkey, EventLog, Preferences
  Learning/     LearningEngine
  Debug/        DebugOverlay, PoseRecorder
GlanzowTests/   XCTest suites (filter, classifier, switch timelines, calibration math, display identity, learning)
ReplayCLI/      replays recorded pose JSON through the pipeline with a logging FocusManager
```

Everything except `App/` builds into the `GlanzowKit` library, so the tests and `ReplayCLI`
use exactly the code the app runs.

## Known limits

- Window and split-pane focus within one screen (Phase 2) is not built.
- The last window is remembered per display, not per Space; a window on a hidden Space falls
  back to the frontmost visible one.
- Mission Control is detected from the Dock's own open/close notifications. If Glanzow ever
  refuses to switch, the debug overlay's "blocked by" line names the reason.
- Head tilt is not corrected, only filtered (samples tilted over 30° are ignored); see the
  `// SPEC:` note in `PoseTracker.swift` for the one recording that would settle it.
- Pupil tracking exists but is off by default and unused by the V1 screen choice.
- Call-app detection covers Zoom, Teams, FaceTime, Webex and Skype; browser calls and screen
  sharing need adding to Excluded Apps by hand.
- The performance, accuracy and false-switch targets (NFR-01 to NFR-06) need measuring on real
  hardware with the camera running; see the event log above.
