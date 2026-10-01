import AppKit
import SwiftUI
import GlanceFocusKit

/// §3.9 settings. Values persist in UserDefaults via @AppStorage; the app reacts to changes.
struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        TabView {
            GeneralSettings(model: model).tabItem { Label("General", systemImage: "gearshape") }
            ExcludedAppsSettings().tabItem { Label("Excluded Apps", systemImage: "nosign") }
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
                Slider(value: $value, in: range, step: step)
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
    @AppStorage(Pref.movePointer) private var movePointer = true
    @AppStorage(Pref.flashOnSwitch) private var flash = true
    @AppStorage(Pref.showActiveBorder) private var border = false
    @AppStorage(Pref.learnFromClicks) private var learn = true

    var body: some View {
        Form {
            Section("Switching") {
                LabeledSlider(title: "Delay before switching", value: $dwellMs, range: 100...1000, step: 50) { "\(Int($0)) ms" }
                LabeledSlider(title: "Head turn needed", value: $headTurn, range: 0...1, step: 0.05) { "\(Int(($0 * 100).rounded()))%" }
                Toggle("Wait while typing", isOn: $waitWhileTyping)
                LabeledSlider(title: "Typing pause", value: $typingPause, range: 0.5...10, step: 0.5, text: seconds)
                    .disabled(!waitWhileTyping)
                LabeledSlider(title: "Mouse quiet period", value: $mouseQuiet, range: 0.5...5, step: 0.1, text: seconds)
                Toggle("Confirm mode: switch only when I double-tap Fn", isOn: $confirmMode)
            }
            Section("Feedback") {
                Toggle("Move pointer with focus", isOn: $movePointer)
                Toggle("Flash on switch", isOn: $flash)
                Toggle("Show active window border", isOn: $border)
            }
            Section("Learning") {
                Toggle("Learn from clicks", isOn: $learn)
            }
            Section("System") {
                Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
            }
        }
        .formStyle(.grouped)
    }
}

/// FR-SAF-07: bundle IDs GlanceFocus never switches into or away from.
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
                Text("GlanceFocus never switches into or away from these apps — useful for video calls and full-screen games.")
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
