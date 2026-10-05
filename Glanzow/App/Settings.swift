import AppKit
import SwiftUI
import GlanzowKit

/// §3.9 settings. Values persist in UserDefaults via @AppStorage; the app reacts to changes.
struct SettingsView: View {
    @ObservedObject var model: AppModel
    let showDebug: Bool

    var body: some View {
        TabView {
            GeneralSettings(model: model).tabItem { Label("General", systemImage: "gearshape") }
            CameraSettings().tabItem { Label("Camera", systemImage: "camera") }
            CalibrationSettings(model: model).tabItem { Label("Calibration", systemImage: "scope") }
            ExcludedAppsSettings().tabItem { Label("Excluded Apps", systemImage: "nosign") }
            if showDebug {
                DebugSettings(model: model).tabItem { Label("Debug", systemImage: "ladybug") }
            }
        }
        .frame(width: 520, height: 560)
    }
}

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let text: (Double) -> String

    var body: some View {
        LabeledContent(title) {
            HStack {
                // Snaps to `step` without drawing a tick per step, which crowds long ranges.
                Slider(value: Binding(get: { value }, set: { value = ($0 / step).rounded() * step }), in: range)
                    .accessibilityLabel(title)
                    .accessibilityValue(text(value))
                Text(text(value)).monospacedDigit().frame(width: 64, alignment: .trailing)
                    .accessibilityHidden(true)
            }
        }
    }
}

private func seconds(_ v: Double) -> String { String(format: "%.1f s", v) }

struct GeneralSettings: View {
    @ObservedObject var model: AppModel
    @AppStorage(Pref.dwellMs) private var dwellMs = 300.0
    @AppStorage(Pref.headTurn) private var headTurn = 0.5
    @AppStorage(Pref.waitWhileTyping) private var waitWhileTyping = true
    @AppStorage(Pref.typingPause) private var typingPause = 3.0
    @AppStorage(Pref.mouseQuiet) private var mouseQuiet = 1.5
    @AppStorage(Pref.confirmMode) private var confirmMode = false
    @AppStorage(Pref.confirmKey) private var confirmKey = "fn"
    @AppStorage(Pref.movePointer) private var movePointer = true
    @AppStorage(Pref.flashOnSwitch) private var flash = true
    @AppStorage(Pref.showActiveBorder) private var border = false
    @AppStorage(Pref.learnFromClicks) private var learn = true
    @AppStorage(Pref.focusWithinScreen) private var withinScreen = true
    @AppStorage(Pref.focusPanes) private var panes = true
    @AppStorage(Pref.paneClickFallback) private var paneClick = false

    var body: some View {
        Form {
            Section {
                LabeledSlider(title: "Delay before switching", value: $dwellMs, range: 100...1000, step: 50) { "\(Int($0)) ms" }
                LabeledSlider(title: "Head turn needed", value: $headTurn, range: 0...1, step: 0.05) { "\(Int(($0 * 100).rounded()))%" }
                Toggle("Wait while typing", isOn: $waitWhileTyping)
                LabeledSlider(title: "Typing pause", value: $typingPause, range: 0.5...10, step: 0.5, text: seconds)
                    .disabled(!waitWhileTyping)
                LabeledSlider(title: "Mouse quiet period", value: $mouseQuiet, range: 0.5...5, step: 0.1, text: seconds)
                Toggle("Switch only when I confirm", isOn: $confirmMode)
                Picker("Confirm by double-tapping", selection: $confirmKey) {
                    Text("Fn").tag("fn")
                    Text("⌃ Control").tag("control")
                    Text("⌥ Option").tag("option")
                    Text("⌘ Command").tag("command")
                }
                .disabled(!confirmMode)
            } header: {
                Text("Switching")
            } footer: {
                Text("Glanzow moves focus once you've faced a new screen for the delay. Head turn needed sets how clearly you must face it. While you type or use the mouse, it waits.")
                    .frame(maxWidth: .infinity, alignment: .leading).multilineTextAlignment(.leading)
            }
            Section {
                Toggle("Focus the window I'm looking at", isOn: $withinScreen)
                Toggle("Focus split panes in terminals and editors", isOn: $panes)
                    .disabled(!withinScreen)
                Toggle("Click a pane when its app ignores Accessibility", isOn: $paneClick)
                    .disabled(!withinScreen || !panes)
            } header: {
                Text("Within a screen")
            } footer: {
                Text("Uses where your eyes point, so it needs a calibration made with this version. Side-by-side windows and panes work best; stacked or narrow ones are harder to tell apart. Browsers and chat apps switch whole windows only. The click fallback may move the text cursor in editors.")
                    .frame(maxWidth: .infinity, alignment: .leading).multilineTextAlignment(.leading)
            }
            Section("Feedback") {
                Toggle("Move pointer with focus", isOn: $movePointer)
                Toggle("Flash on switch", isOn: $flash)
                Toggle("Show active window border", isOn: $border)
            }
            Section {
                Toggle("Learn from clicks", isOn: $learn)
            } header: {
                Text("Learning")
            } footer: {
                Text("Each click fine-tunes the calibration for that screen. If clicks keep disagreeing with Glanzow, it suggests recalibrating.")
                    .frame(maxWidth: .infinity, alignment: .leading).multilineTextAlignment(.leading)
            }
            Section("System") {
                HotkeyRecorder()
                Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
            }
        }
        .formStyle(.grouped)
    }
}

/// FR-SAF-07: bundle IDs Glanzow never switches into or away from.
struct ExcludedAppsSettings: View {
    @State private var apps = UserDefaults.standard.stringArray(forKey: Pref.excludedApps) ?? []
    @State private var newID = ""

    var body: some View {
        Form {
            Section {
                if apps.isEmpty { Text("No excluded apps").foregroundStyle(.secondary) }
                ForEach(apps, id: \.self) { id in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(Self.name(id))
                            Text(id).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove") { save(apps.filter { $0 != id }) }
                            .accessibilityLabel("Remove \(Self.name(id))")
                    }
                }
            } header: {
                Text("Glanzow never switches into or away from these apps — useful for video calls and full-screen games.")
            }
            Section("Add") {
                Menu("Add Running App") {
                    ForEach(Self.runningApps(), id: \.self) { id in
                        Button(Self.name(id)) { save(apps + [id]) }
                    }
                }
                HStack {
                    TextField("Bundle ID", text: $newID, prompt: Text("com.example.App"))
                    Button("Add") { save(apps + [newID]); newID = "" }
                        .disabled(newID.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func save(_ list: [String]) {
        var seen = Set<String>()
        apps = list.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && seen.insert($0).inserted }
        UserDefaults.standard.set(apps, forKey: Pref.excludedApps)
    }

    static func name(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    static func runningApps() -> [String] {
        let ids = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.bundleIdentifier)
        return Array(Set(ids)).sorted { name($0).localizedCaseInsensitiveCompare(name($1)) == .orderedAscending }
    }
}

/// FR-TRK-07: every video device; the choice persists by unique ID.
struct CameraSettings: View {
    @AppStorage(Pref.cameraID) private var cameraID = ""
    @State private var devices = CameraCapture.devices().map { (id: $0.uniqueID, name: $0.localizedName) }

    var body: some View {
        Form {
            Picker("Camera", selection: $cameraID) {
                Text("Built-in camera (default)").tag("")
                ForEach(devices, id: \.id) { Text($0.name).tag($0.id) }
                if !cameraID.isEmpty && !devices.contains(where: { $0.id == cameraID }) {
                    Text("Saved camera (not connected)").tag(cameraID)
                }
            }
            Text("If the chosen camera is missing, Glanzow uses the built-in one. Calibration belongs to one camera, so switching cameras asks you to calibrate again.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .onAppear { devices = CameraCapture.devices().map { (id: $0.uniqueID, name: $0.localizedName) } }
    }
}

/// §6.2 hidden debug pane: filter and classifier tuning, pupil tracking, overlay, recording.
struct DebugSettings: View {
    @ObservedObject var model: AppModel
    @AppStorage(Pref.minCutoff) private var minCutoff = 1.0
    @AppStorage(Pref.beta) private var beta = 0.05
    @AppStorage(Pref.dCutoff) private var dCutoff = 1.0
    @AppStorage(Pref.rejectThreshold) private var rejectThreshold = 4.0
    @AppStorage(Pref.trackPupils) private var trackPupils = false
    @AppStorage(Pref.showDebugOverlay) private var showOverlay = false

    var body: some View {
        Form {
            Section("Smoothing (One Euro filter)") {
                LabeledSlider(title: "Min cutoff", value: $minCutoff, range: 0.1...5, step: 0.1) { String(format: "%.1f Hz", $0) }
                LabeledSlider(title: "Beta", value: $beta, range: 0...0.5, step: 0.005) { String(format: "%.3f", $0) }
                LabeledSlider(title: "Derivative cutoff", value: $dCutoff, range: 0.1...5, step: 0.1) { String(format: "%.1f Hz", $0) }
            }
            Section("Classifier") {
                LabeledSlider(title: "Off-screen threshold", value: $rejectThreshold, range: 1...10, step: 0.5) { String(format: "%.1f", $0) }
            }
            Section("Tracking") {
                Toggle("Track pupils (more CPU; not used for screen choice in V1)", isOn: $trackPupils)
                Toggle("Show debug overlay", isOn: $showOverlay)
            }
            #if DEBUG
            Section("Recording") {
                Button(model.isRecording ? "Stop Recording" : "Start Recording") { model.toggleRecording() }
                Text("Records pose numbers and input timing for ReplayCLI. Never images.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            #endif
            Button("Reset Debug Values") {
                for key in [Pref.minCutoff, Pref.beta, Pref.dCutoff, Pref.rejectThreshold, Pref.trackPupils] {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// FR-CAL-06: calibration status per display, recalibrate one or all.
struct CalibrationSettings: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section {
                ForEach(model.displays) { d in
                    HStack(spacing: 10) {
                        let ok = model.store.model(d.key).map { model.cameraID.isEmpty || $0.cameraID == model.cameraID } ?? false
                        Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .foregroundStyle(ok ? .green : .orange)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading) {
                            Text(d.name)
                            Text(status(d)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Recalibrate") { Task { await model.calibrate([d.key]) } }
                            .accessibilityLabel("Recalibrate \(d.name)")
                    }
                }
            } footer: {
                if model.displays.contains(where: \.ambiguous) {
                    Text(AppModel.ambiguousNote).frame(maxWidth: .infinity, alignment: .leading).multilineTextAlignment(.leading)
                }
            }
            Button("Recalibrate All Displays") { Task { await model.calibrate(nil) } }
                .disabled(model.calibrating)
        }
        .formStyle(.grouped)
    }

    private func status(_ d: DisplayInfo) -> String {
        guard let m = model.store.model(d.key) else { return "Not calibrated" }
        let date = m.calibratedAt.formatted(date: .abbreviated, time: .shortened)
        if !model.cameraID.isEmpty && m.cameraID != model.cameraID { return "Calibrated \(date) with a different camera" }
        guard let g = m.gaze else { return "Calibrated \(date). Recalibrate to focus windows within it" }
        if g.eyes != nil && !g.eyesCurrent { return "Calibrated \(date). Recalibrate to use eye tracking" }
        return "Calibrated \(date). Window aim within about \(max(1, Int(((g.eyesError ?? g.headError) * 100).rounded())))%"
    }
}

/// FR-SAF-05: rebind the pause shortcut.
/// SPEC: §3.9 says "Any". A shortcut without ⌘, ⌥ or ⌃ would be a global hot key on a plain
/// letter and swallow that letter in every app, so one of those modifiers is required.
struct HotkeyRecorder: View {
    @AppStorage(Pref.hotkeyLabel) private var label = "⇧⌘G"
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        LabeledContent("Pause shortcut") {
            Button(recording ? "Type a shortcut…" : label) { recording ? stop() : start() }
                .accessibilityLabel(recording ? "Recording. Press the new shortcut, or Escape to cancel." : "Pause shortcut \(label). Press to change.")
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 { stop(); return nil } // Escape
            let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
            guard !mods.isDisjoint(with: [.command, .option, .control]) else { NSSound.beep(); return nil }
            let d = UserDefaults.standard
            d.set(Int(e.keyCode), forKey: Pref.hotkeyCode)
            d.set(Int(Hotkey.carbonModifiers(mods)), forKey: Pref.hotkeyModifiers)
            label = Hotkey.label(keyCode: e.keyCode, characters: e.charactersIgnoringModifiers, flags: mods)
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
