import AppKit
import AVFoundation
import SwiftUI
import GlanzowKit

/// §3.9 settings, in Glanzow's own words and order. Values persist in UserDefaults via
/// @AppStorage; the app reacts to every change at once.
struct SettingsView: View {
    @ObservedObject var model: AppModel
    let showDebug: Bool
    @State private var pane: Pane? = .following

    enum Pane: String, CaseIterable, Identifiable {
        case following, windows, eyes, feel, screens, shortcuts, privacy, advanced
        var id: String { rawValue }
        var title: String {
            switch self {
            case .following: "Following"
            case .windows: "Windows & Panes"
            case .eyes: "Eyes"
            case .feel: "Look & Feel"
            case .screens: "Screens"
            case .shortcuts: "Shortcuts"
            case .privacy: "Privacy"
            case .advanced: "Advanced"
            }
        }
        var symbol: String {
            switch self {
            case .following: "" // the app's own mark, below
            case .windows: "rectangle.split.2x1"
            case .eyes: "eye"
            case .feel: "paintbrush"
            case .screens: "display.2"
            case .shortcuts: "keyboard"
            case .privacy: "hand.raised"
            case .advanced: "slider.horizontal.3"
            }
        }
        @ViewBuilder var icon: some View {
            if self == .following {
                Image(nsImage: Glyph.image(.following, description: "")).renderingMode(.template).resizable().scaledToFit().frame(width: 16, height: 16)
            } else {
                Image(systemName: symbol)
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases.filter { $0 != .advanced || showDebug }, selection: $pane) { p in
                Label { Text(p.title) } icon: { p.icon }.tag(p)
            }
            .navigationSplitViewColumnWidth(190)
        } detail: {
            Group {
                switch pane ?? .following {
                case .following: FollowingSettings(model: model)
                case .windows: WindowsSettings()
                case .eyes: EyesSettings()
                case .feel: FeelSettings()
                case .screens: ScreensSettings(model: model)
                case .shortcuts: ShortcutSettings()
                case .privacy: PrivacySettings(model: model)
                case .advanced: AdvancedSettings(model: model)
                }
            }
            .navigationTitle((pane ?? .following).title)
        }
        .frame(width: 760, height: 540)
    }
}

// MARK: Pieces

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

/// A section footer that reads as a sentence: left-aligned, wrapped.
struct Footnote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).frame(maxWidth: .infinity, alignment: .leading).multilineTextAlignment(.leading)
    }
}

private func seconds(_ v: Double) -> String { String(format: "%.1f s", v) }

// MARK: Following

struct FollowingSettings: View {
    @ObservedObject var model: AppModel
    @AppStorage(Pref.adaptiveSettle) private var learn = true
    @AppStorage(Pref.learnedDwellMs) private var learnedMs = 0.0
    @AppStorage(Pref.dwellMs) private var dwellMs = 300.0
    @AppStorage(Pref.headTurn) private var headTurn = 0.5
    @AppStorage(Pref.waitWhileTyping) private var holdTyping = true
    @AppStorage(Pref.typingPause) private var typingPause = 3.0
    @AppStorage(Pref.mouseQuiet) private var mouseQuiet = 1.5
    @AppStorage(Pref.confirmMode) private var confirmMode = false
    @AppStorage(Pref.confirmKey) private var confirmKey = "option"
    @AppStorage(Pref.movePointer) private var movePointer = true

    var body: some View {
        Form {
            Section {
                Toggle("Learn my timing", isOn: $learn)
                if learn {
                    LabeledContent("Settle time") {
                        HStack {
                            Text(learnedMs > 0 ? "\(Int(learnedMs)) ms, learned" : "\(Int(dwellMs)) ms, learning")
                                .foregroundStyle(.secondary)
                            Button("Start Over") { model.resetLearnedSettle() }.disabled(learnedMs == 0)
                        }
                    }
                } else {
                    LabeledSlider(title: "Settle time", value: $dwellMs, range: 100...1000, step: 50) { "\(Int($0)) ms" }
                }
                LabeledSlider(title: "Turn needed", value: $headTurn, range: 0...1, step: 0.05) { v in v < 0.34 ? "Small" : v < 0.67 ? "Medium" : "Large" }
            } header: {
                Text("How focus follows you")
            } footer: {
                Footnote("Settle time is how long you rest on a screen before focus moves there. Learning shortens it when you use switches straight away and lengthens it when you undo one, between 250 and 600 ms. Turn needed is how clearly you must face a new screen.")
            }
            Section {
                Toggle("Hold while I type", isOn: $holdTyping)
                LabeledSlider(title: "For", value: $typingPause, range: 0.5...10, step: 0.5, text: seconds)
                    .disabled(!holdTyping)
                LabeledSlider(title: "Hold after mouse use", value: $mouseQuiet, range: 0.5...5, step: 0.1, text: seconds)
                Toggle("Only switch when I double-tap a key", isOn: $confirmMode)
                Picker("Key", selection: $confirmKey) {
                    Text("⌥ Option").tag("option")
                    Text("⌃ Control").tag("control")
                    Text("⌘ Command").tag("command")
                    Text("Fn").tag("fn")
                }
                .disabled(!confirmMode)
            } header: {
                Text("When to hold still")
            } footer: {
                Footnote("While you type or use the mouse, focus stays put. Holding a look at another screen for a second still moves it, except within a screen.")
            }
            Section {
                Toggle("Bring the pointer along", isOn: $movePointer)
                Toggle("Open Glanzow when I log in", isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Windows & panes

struct WindowsSettings: View {
    @AppStorage(Pref.focusWithinScreen) private var windows = true
    @AppStorage(Pref.focusPanes) private var panes = true
    @AppStorage(Pref.paneClickFallback) private var paneClick = false

    var body: some View {
        Form {
            Section {
                Toggle("Follow my eyes to windows", isOn: $windows)
                Toggle("…and to split panes", isOn: $panes).disabled(!windows)
            } footer: {
                Footnote("On one screen, Glanzow follows your eyes to the window or pane you rest on for about half a second. Side-by-side windows work best; stacked or very narrow panes are harder to tell apart. Needs screens taught with this version.")
            }
            Section {
                LabeledContent("Panes in", value: "iTerm2, Terminal, VS Code, Cursor, Zed, Xcode, Ghostty, WezTerm, JetBrains IDEs")
                LabeledContent("Whole windows in", value: "browsers, chat, documents and everything else")
            } footer: {
                Footnote("Page regions in a browser never take focus on their own.")
            }
            Section {
                Toggle("Click a pane when its app ignores requests", isOn: $paneClick).disabled(!windows || !panes)
            } footer: {
                Footnote("A last resort for apps that refuse both Accessibility and their own pane shortcut. A click can move the text cursor in an editor.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Eyes

struct EyesSettings: View {
    @AppStorage(Pref.eyeBreaks) private var breaks = false
    @AppStorage(Pref.privacyGuard) private var privacy = false

    var body: some View {
        Form {
            Section {
                Toggle("Eye breaks", isOn: $breaks)
            } footer: {
                Footnote("Every 20 minutes of screen time, a gentle nudge to look at something far away. The break completes on its own once you've looked away for 20 seconds.")
            }
            Section {
                Toggle("Privacy guard", isOn: $privacy)
            } footer: {
                Footnote("If someone else is watching your screen for more than two seconds, Glanzow softly veils it until they look away. Nothing is recorded.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Look & feel

struct FeelSettings: View {
    @AppStorage(Pref.feedbackStyle) private var style = "spotlight"
    @AppStorage(Pref.showActiveBorder) private var border = false

    var body: some View {
        Form {
            Section {
                Picker("When focus moves", selection: $style) {
                    Text("Spotlight the window").tag("spotlight")
                    Text("Glow around the window").tag("ring")
                    Text("Nothing").tag("none")
                }
                .pickerStyle(.radioGroup)
            } footer: {
                Footnote("Spotlight briefly dims everything around the window that now has focus, so it reads on light and dark windows alike.")
            }
            Section {
                Toggle("Keep a border on the focused window", isOn: $border)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Screens

struct ScreensSettings: View {
    @ObservedObject var model: AppModel
    @AppStorage(Pref.cameraID) private var cameraID = ""
    @State private var cameras = CameraCapture.devices().map { (id: $0.uniqueID, name: $0.localizedName) }

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
                        Button("Teach Again") { Task { await model.calibrate([d.key]) } }
                            .accessibilityLabel("Teach \(d.name) again")
                    }
                }
                Button("Teach All Screens") { Task { await model.calibrate(nil) } }.disabled(model.calibrating)
            } header: {
                Text("Your screens")
            } footer: {
                if model.displays.contains(where: \.ambiguous) { Footnote(AppModel.ambiguousNote) }
            }
            Section {
                Picker("Camera", selection: $cameraID) {
                    Text("Built-in camera").tag("")
                    ForEach(cameras, id: \.id) { Text($0.name).tag($0.id) }
                    if !cameraID.isEmpty && !cameras.contains(where: { $0.id == cameraID }) {
                        Text("Saved camera (not connected)").tag(cameraID)
                    }
                }
            } footer: {
                Footnote("If the chosen camera is missing, Glanzow uses the built-in one. What it learned belongs to one camera, so a new camera means teaching your screens again.")
            }
        }
        .formStyle(.grouped)
        .onAppear { cameras = CameraCapture.devices().map { (id: $0.uniqueID, name: $0.localizedName) } }
    }

    private func status(_ d: DisplayInfo) -> String {
        guard let m = model.store.model(d.key) else { return "Not taught yet" }
        let date = m.calibratedAt.formatted(date: .abbreviated, time: .shortened)
        if !model.cameraID.isEmpty && m.cameraID != model.cameraID { return "Taught \(date) with a different camera" }
        guard let g = m.gaze else { return "Taught \(date). Teach again to follow your eyes within it" }
        if g.eyes != nil && !g.eyesCurrent { return "Taught \(date). Teach again to use eye tracking" }
        return "Taught \(date). Window aim within about \(max(1, Int(((g.eyesError ?? g.headError) * 100).rounded())))%"
    }
}

// MARK: Shortcuts

struct ShortcutSettings: View {
    var body: some View {
        Form {
            Section {
                HotkeyRecorder(title: "Hold or follow", code: Pref.hotkeyCode, modifiers: Pref.hotkeyModifiers, label: Pref.hotkeyLabel, fallback: "⌃⌥H")
                HotkeyRecorder(title: "Undo last switch", code: Pref.undoHotkeyCode, modifiers: Pref.undoHotkeyModifiers, label: Pref.undoHotkeyLabel, fallback: "⌃⌥Z")
            } footer: {
                Footnote("Undo puts focus back where it was and waits until you look somewhere else. Each undo also teaches Glanzow to be a little more patient.")
            }
        }
        .formStyle(.grouped)
    }
}

/// FR-SAF-05: rebind a global shortcut.
/// SPEC: §3.9 says "Any". A shortcut without ⌘, ⌥ or ⌃ would be a global hot key on a plain
/// letter and swallow that letter in every app, so one of those modifiers is required.
struct HotkeyRecorder: View {
    let title: String
    let code: String
    let modifiers: String
    let label: String
    let fallback: String
    @State private var recording = false
    @State private var monitor: Any?
    @State private var shown = ""

    var body: some View {
        LabeledContent(title) {
            Button(recording ? "Type a shortcut…" : shown) { recording ? stop() : start() }
                .accessibilityLabel(recording ? "Recording. Press the new shortcut, or Escape to cancel." : "\(title) shortcut \(shown). Press to change.")
        }
        .onAppear { shown = UserDefaults.standard.string(forKey: label) ?? fallback }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 { stop(); return nil } // Escape
            let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
            guard !mods.isDisjoint(with: [.command, .option, .control]) else { NSSound.beep(); return nil }
            let d = UserDefaults.standard
            d.set(Int(e.keyCode), forKey: code)
            d.set(Int(Hotkey.carbonModifiers(mods)), forKey: modifiers)
            shown = Hotkey.label(keyCode: e.keyCode, characters: e.charactersIgnoringModifiers, flags: mods)
            d.set(shown, forKey: label)
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

// MARK: Privacy

struct PrivacySettings: View {
    @ObservedObject var model: AppModel
    @AppStorage(Pref.restWhenAway) private var rest = true
    @State private var apps = UserDefaults.standard.stringArray(forKey: Pref.excludedApps) ?? []
    @State private var newID = ""
    @State private var confirmErase = false

    var body: some View {
        Form {
            Section("What Glanzow sees and keeps") {
                Label("Camera frames are read in memory and dropped at once. Nothing is saved, nothing leaves your Mac, and Glanzow makes no network connections at all.", systemImage: "camera")
                Label("It keeps only numbers: head and eye angles learned for your screens, and a log of switch timings.", systemImage: "number")
                Label("It notes when you type, never what you type.", systemImage: "keyboard")
            }
            Section {
                Toggle("Rest the camera when I'm away", isOn: $rest)
            } footer: {
                Footnote("After two minutes without you in view or at the keyboard, the camera turns off and its light goes out. Touch any key or the mouse to bring it back.")
            }
            Section {
                if apps.isEmpty { Text("None").foregroundStyle(.secondary) }
                ForEach(apps, id: \.self) { id in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(Self.name(id))
                            Text(id).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove") { save(apps.filter { $0 != id }) }.accessibilityLabel("Remove \(Self.name(id))")
                    }
                }
                HStack {
                    Menu("Add Running App") {
                        ForEach(Self.runningApps(), id: \.self) { id in Button(Self.name(id)) { save(apps + [id]) } }
                    }
                    .fixedSize()
                    TextField("Bundle ID", text: $newID, prompt: Text("com.example.App"))
                    Button("Add") { save(apps + [newID]); newID = "" }
                        .disabled(newID.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Leave these apps alone")
            } footer: {
                Footnote("Glanzow never moves focus into or out of these apps. Useful for video calls, presentations and full-screen games.")
            }
            Section {
                Button("Erase Everything Glanzow Has Learned…", role: .destructive) { confirmErase = true }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Erase everything Glanzow has learned?", isPresented: $confirmErase) {
            Button("Erase", role: .destructive) { model.eraseLearnedData() }
        } message: {
            Text("This removes what it learned about your screens, your timing and the switch log. You'll teach it your screens again.")
        }
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
        let ids = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.compactMap(\.bundleIdentifier)
        return Array(Set(ids)).sorted { name($0).localizedCaseInsensitiveCompare(name($1)) == .orderedAscending }
    }
}

// MARK: Advanced

/// §6.2 hidden debug pane: filter and classifier tuning, pupil tracking, overlay, recording.
struct AdvancedSettings: View {
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
                Toggle("Always track eyes (more CPU)", isOn: $trackPupils)
                Toggle("Show debug overlay", isOn: $showOverlay)
            }
            #if DEBUG
            Section("Recording") {
                Button(model.isRecording ? "Stop Recording" : "Start Recording") { model.toggleRecording() }
                Text("Records pose numbers and input timing for ReplayCLI. Never images.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            #endif
            Button("Reset Advanced Values") {
                for key in [Pref.minCutoff, Pref.beta, Pref.dCutoff, Pref.rejectThreshold, Pref.trackPupils] {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
        }
        .formStyle(.grouped)
    }
}
