# Glanzow

Glanzow is a Mac menu bar app. It uses the Mac's camera to see where you're looking, and moves
keyboard focus there before you start typing: to the screen you face, and within it to the
window or split pane your eyes rest on. It waits while you type or use the mouse, so it never
steals keystrokes mid-sentence.

Everything runs on the Mac. Camera frames are processed in memory and dropped; nothing is saved
to disk and the app makes no network calls at all.

The full requirements are in `requirements.pdf`. Code comments cite its requirement IDs
(`FR-FOC-01`, `NFR-04`, …), and every place where the spec was ambiguous carries a `// SPEC:`
comment explaining the choice.

## Using it

Click the gleam ✦ in the menu bar for the panel: a live view of your screens with the gleam
where you're looking, a Hold switch, and four quick toggles. Right-click it for the menu.

| Shortcut | What it does |
|---|---|
| ⌃⌥H | Hold focus where it is / follow me again |
| ⌃⌥Z | Undo the last switch (and teach Glanzow to be a little more patient) |

Both can be changed in Settings › Shortcuts.

| Feature | Default | What it does |
|---|---|---|
| Screens | on | Focus moves to the screen you settle on (Settle time, learned from your undos and quick returns, 250–600 ms) |
| Windows & panes | on | Within a screen, focus moves to the window or split pane your eyes rest on for about half a second. Panes in iTerm2, Terminal, VS Code, Cursor, Zed, Xcode, Ghostty, WezTerm and JetBrains IDEs; whole windows everywhere else |
| Eye breaks | off | Every 20 minutes of screen time, a nudge to look far away; it completes once you have |
| Privacy guard | off | Someone else watching your screen for 2 s frosts it over until they look away |
| Camera rest | on | Two minutes without you in view or at the keyboard turns the camera off until you're back |

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
camera ─▶ face pose (Vision) ─▶ iris centres ─▶ smoothing ─▶ which screen ─▶ where on it ─▶ focus
          yaw, pitch, roll     (gradients)      (One Euro)   (clusters)       (gaze map +      (raise,
                                                                              fixation)        warp)
```

Each step is a published, widely used method rather than an invention:

| Step | Method |
|---|---|
| Head pose | Apple Vision face rectangles, revision 3 |
| Iris centre | Gradient-based eye-centre localisation (Timm & Barth, VISAPP 2011), on a small patch between the eye corners; glints from glasses are ignored by construction |
| Smoothing | One Euro filter (Casiez, Roussel & Vogel, CHI 2012) |
| Which screen | Nearest cluster by Mahalanobis distance, with a hysteresis margin and a dwell before switching |
| Where on the screen | A ridge-regularised linear map from head and eye angles to screen position, fitted during calibration and refitted from your clicks as you work (WebGazer, Papoutsaki et al., IJCAI 2016) |
| Window or pane choice | Dispersion-threshold fixation detection, I-DT (Salvucci & Goldberg, ETRA 2000) |
| Calibration | Smooth-pursuit calibration (Pfeuffer et al., UIST 2013): follow a gleam around each screen; then nine fixed points, the classic grid, looked at eyes-first as in real use |

1. **Calibration** ("Teach my screens") has you follow a gleam that glides once around each
   screen, then look at nine spots it jumps between. Every frame becomes a training pair: where
   your head and eyes pointed, and where the gleam was. A gliding gleam is easy to follow with your
   head; a jumping one is looked at eyes-first, the way you look at things in real use, so it is
   what teaches the up-and-down role of the eyes.
2. **Which screen**: each frame is matched to the nearest screen's cluster. A pose far from every
   screen (phone, desk) does nothing. A new screen must win for the settle time.
3. **Where on the screen**: the gaze map turns head and eye angles into a point. When your eyes
   rest (a fixation of about half a second) clearly inside another window or pane, focus moves
   there. Panes are focused through Accessibility, or with the app's own pane shortcut when it
   ignores that (iTerm2: ⌥⌘arrow; VS Code: ⌘K ⌘arrow), always checked afterwards.
4. **Never interrupting**: nothing moves while you type (screens allow a deliberate one-second
   look to override; windows and panes never do), use the mouse, or have a menu, dialog, sheet,
   password field, screenshot tool or Mission Control open, or while an excluded app is in front.
5. **Feedback**: a brief spotlight dims everything around the newly focused window. It is clear
   for your first 50 switches and lighter after that.
6. **Learning**: clicks refine the gaze map and the screen clusters; undos and quick returns
   tune the settle time.

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

## Security and privacy

- No network code and no third-party libraries. `make verify` (run after every release build)
  checks the camera is the only entitlement, the hardened runtime is on (no debugger attach, no
  library injection), no debug-only code is present, and only Apple system libraries are linked.
- Frames never leave memory. Stored data is numbers only, in `~/Library/Application Support/Glanzow`
  (folder 0700, files 0600). Settings › Privacy can erase all of it.
- Keystrokes: a listen-only event tap records *when* keys are pressed, never which.
- Lock and screensaver state is verified with the system before the camera resumes (the
  notifications themselves can be faked by any process), with a 30-second watchdog.
- The calibration file is validated on load; malformed numbers or shapes are discarded, not trusted.
- Pane shortcuts are delivered only to the target app's process, only while it is frontmost, and
  only when you aren't typing; the opt-in click fallback first checks the point really is inside
  the target pane.

## Measuring it

`make diagnostics` writes one text file to the Desktop: settings, calibration quality per screen
(including "window aim"), switch timings (median and 90th percentile), undo counts, a 60-second
CPU and memory sample, and recent log lines. Numbers only. Glanzow also logs a `perf` line every
minute: process CPU, frames analysed, time per frame in face and eye analysis, and memory.

## Known limits

- Webcam eye tracking is region-level, not pixel-level: expect roughly 5–10% of the screen width.
  Side-by-side windows and panes work best; stacked or narrow ones are harder.
- VS Code pane discovery relies on Electron's accessibility tree; it couldn't be inspected while
  building, so check the debug overlay's "region" line.
- Head tilt is filtered (samples tilted over 30° are ignored), not corrected.
- Call-app detection covers Zoom, Teams, FaceTime, Webex and Skype; browser calls and screen
  sharing need adding to "Leave these apps alone" by hand.
- Releasing publicly needs a Developer ID certificate (paid Apple Developer Program) for
  notarization. Also check that the name "Glanzow" is free to use.
