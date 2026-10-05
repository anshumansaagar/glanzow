import SwiftUI
import GlanzowKit

/// FR-ONB-01…05, as one page instead of a wizard: three things to switch on, all visible at
/// once, in a suggested order, each showing its own state. Reopened from the menu (FR-ONB-04).
struct OnboardingView: View {
    @ObservedObject var model: AppModel
    @State private var launchAtLogin = true
    @State private var calibrationNote: String?
    @State private var calibrating = false
    @State private var askedForAccess = false

    init(model: AppModel) { self.model = model }

    private var cameraDone: Bool { model.cameraAuthorized }
    private var accessDone: Bool { model.permissionsGranted }
    private var screensDone: Bool {
        if let note = calibrationNote { return note.hasPrefix("Calibrated") }
        return !model.displays.isEmpty && model.displays.allSatisfy { model.store.model($0.key) != nil }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScreenStage(displays: model.displays, lit: litScreen, gleam: nil)
                .frame(height: 170)
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Three things, then Glanzow follows you")
                        .font(.system(size: 22, weight: .semibold).width(.expanded))
                        .accessibilityAddTraits(.isHeader)
                    Text("Look at a screen, a window or a pane, and keyboard focus is already there when you start typing.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(spacing: 8) {
                    StepRow(number: 1, title: "Let Glanzow see you",
                            detail: "Frames stay in memory: nothing is saved or sent. The camera light is on while it watches.",
                            done: cameraDone, current: !cameraDone) {
                        if model.cameraDenied {
                            Button("Open Camera Settings") { AppModel.openPrivacySettings("Privacy_Camera") }
                        } else {
                            Button("Allow Camera") { Task { await model.requestCamera() } }
                        }
                    }
                    StepRow(number: 2, title: "Let it move focus for you",
                            detail: "Accessibility lets it bring windows forward. It notes when you type, never what you type.",
                            done: accessDone, current: cameraDone && !accessDone) {
                        if model.axTrusted {
                            Button("Allow Input Monitoring") { model.requestInputMonitoring() }
                        } else if askedForAccess {
                            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Waiting…").foregroundStyle(.secondary) }
                        } else {
                            Button("Allow Accessibility") { askedForAccess = true; model.requestAccessibility() }
                        }
                    }
                    StepRow(number: 3, title: "Teach it your screens",
                            detail: calibrationNote ?? "A gleam glides around each screen, then jumps between a few spots. Follow it with your eyes, about 25 seconds a screen.",
                            done: screensDone, current: accessDone && !screensDone) {
                        if calibrating {
                            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Learning…").foregroundStyle(.secondary) }
                        } else {
                            Button(screensDone ? "Teach Again" : "Start") { runCalibration() }
                                .disabled(!cameraDone || !accessDone)
                        }
                    }
                }
                Spacer(minLength: 0)
                HStack {
                    Toggle("Open Glanzow when I log in", isOn: $launchAtLogin)
                    Spacer()
                    Button(screensDone ? "Start Following" : "Finish Later") { model.finishOnboarding(launchAtLogin: launchAtLogin) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!cameraDone || !accessDone)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .padding(.bottom, 22)
        }
        .frame(width: 620, height: 560)
        .background(.background)
    }

    /// The gleam lights the screen with the camera first, then moves on as steps are done.
    private var litScreen: DisplayKey? {
        guard let builtin = model.displays.firstIndex(where: \.isBuiltin) ?? (model.displays.isEmpty ? nil : 0) else { return nil }
        let done = [cameraDone, accessDone, screensDone].filter { $0 }.count
        return model.displays[(builtin + done) % model.displays.count].key
    }

    private func runCalibration() {
        calibrating = true
        Task {
            calibrationNote = await model.calibrate(nil)
            calibrating = false
        }
    }
}

/// One numbered step: its state on the left, what it's for, and its action on the right.
private struct StepRow<Action: View>: View {
    let number: Int
    let title: String
    let detail: String
    let done: Bool
    let current: Bool
    @ViewBuilder let action: () -> Action

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle().fill(done ? Color.green : (current ? Color.accentColor : Color.primary.opacity(0.08)))
                if done {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                } else {
                    Text("\(number)").font(.system(size: 13, weight: .semibold)).foregroundStyle(current ? .white : .secondary)
                }
            }
            .frame(width: 28, height: 28)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if done {
                Text("Done").font(.system(size: 12, weight: .medium)).foregroundStyle(.green)
            } else {
                action().controlSize(.regular)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(current ? 0.06 : 0.03)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(current ? Color.accentColor.opacity(0.45) : .clear))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Step \(number), \(title), \(done ? "done" : "not done yet")")
    }
}
