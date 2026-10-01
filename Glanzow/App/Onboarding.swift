import SwiftUI
import GlanzowKit

/// FR-ONB-01: four steps — camera, Accessibility, calibration, done. Reopened from the menu (FR-ONB-04).
/// A night stage at the top draws the user's own display arrangement; the gleam moves to a
/// different screen at each step, which is the whole idea of the app in one picture.
struct OnboardingView: View {
    @ObservedObject var model: AppModel
    @State private var step = 0
    @State private var launchAtLogin = true
    @State private var calibrationNote: String?
    @State private var calibrating = false
    @State private var askedForAccess = false
    private let pinned: Bool

    /// `step` pins the starting step (snapshots); otherwise it follows the permissions granted.
    init(model: AppModel, step: Int? = nil) {
        self.model = model
        _step = State(initialValue: step ?? 0)
        pinned = step != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            Stage(displays: model.displays, step: step)
                .frame(height: 210)
            VStack(alignment: .leading, spacing: 0) {
                content
                    .frame(maxWidth: 500, alignment: .leading)
                    .id(step)
                    .transition(.opacity)
                Spacer(minLength: 16)
                HStack(spacing: 12) {
                    if step > 0 {
                        Button("Back") { go(step - 1) }
                            .buttonStyle(.borderless)
                    }
                    Spacer()
                    secondaryAction
                        .controlSize(.large)
                    primaryAction
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 26)
            .padding(.bottom, 24)
        }
        .frame(width: 620, height: 490)
        .background(.background)
        .onAppear { if !pinned { step = !model.cameraAuthorized ? 0 : !model.permissionsGranted ? 1 : step } }
        .onChange(of: model.cameraAuthorized) { _, ok in if ok && step == 0 { go(1) } }
        .onChange(of: model.permissionsGranted) { _, ok in if ok && step == 1 { go(2) } } // FR-ONB-03 auto-advance
    }

    private func go(_ s: Int) {
        withAnimation(.easeInOut(duration: 0.25)) { step = s }
    }

    // MARK: Steps

    @ViewBuilder private var content: some View {
        switch step {
        case 0:
            StepText(title: "Focus follows where you look",
                     text: "Glanzow uses your Mac's camera to see which screen you're facing, and moves keyboard focus there before you type.",
                     note: "Frames stay in memory: nothing is saved, nothing is sent anywhere. The camera light stays on while Glanzow is tracking.")
            if model.cameraAuthorized { Granted("Camera access is on") }
            if model.cameraDenied { Problem("Camera access is off for Glanzow. Turn it on in System Settings, then come back.") }
        case 1:
            StepText(title: "Let Glanzow bring windows forward",
                     text: "Accessibility access lets Glanzow raise the window you last used on each screen and move the pointer with it.",
                     note: "It notes when you type so it never interrupts you, but never what you type.")
            if model.permissionsGranted {
                Granted("Accessibility access is on")
            } else if model.axTrusted {
                Problem("This Mac also needs Input Monitoring, so Glanzow can wait while you type.")
            } else if askedForAccess {
                Waiting("Waiting for access. Turn on Glanzow in the list that opened.")
            }
        case 2:
            StepText(title: "Teach it your screens",
                     text: "A light moves around each screen for about 20 seconds. Turn your head to follow it, the way you'd naturally look there. Then you'll look at each screen once more to check.",
                     note: "Press Esc to stop at any time.")
            if calibrating {
                Waiting("Calibrating. Follow the light.")
            } else if let calibrationNote {
                if calibrationNote.hasPrefix("Calibrated") { Granted(calibrationNote) } else { Problem(calibrationNote) }
            }
        default:
            StepText(title: "You're set",
                     text: "Look at a screen and stay there for a moment: focus moves with you. Glanzow waits while you type or use the mouse.",
                     note: "Pause any time with \(UserDefaults.standard.string(forKey: Pref.hotkeyLabel) ?? "⇧⌘G") or from the menu bar. Recalibrate there too if you move your laptop or monitors.")
            Toggle("Open Glanzow when I log in", isOn: $launchAtLogin)
                .padding(.top, 14)
        }
    }

    @ViewBuilder private var primaryAction: some View {
        switch step {
        case 0:
            if model.cameraAuthorized {
                Button("Continue") { go(1) }
            } else if model.cameraDenied {
                Button("Open Camera Settings") { AppModel.openPrivacySettings("Privacy_Camera") }
            } else {
                Button("Allow Camera Access") { Task { await model.requestCamera() } }
            }
        case 1:
            if model.permissionsGranted {
                Button("Continue") { go(2) }
            } else if model.axTrusted {
                Button("Open Input Monitoring Settings") { model.requestInputMonitoring() }
            } else {
                Button("Open Accessibility Settings") {
                    askedForAccess = true
                    model.requestAccessibility()
                }
            }
        case 2:
            if calibrationNote?.hasPrefix("Calibrated") == true {
                Button("Continue") { go(3) }
            } else {
                Button(calibrating ? "Calibrating…" : "Start Calibration") { runCalibration() }
                    .disabled(calibrating || !model.permissionsGranted)
            }
        default:
            Button("Finish") { model.finishOnboarding(launchAtLogin: launchAtLogin) }
        }
    }

    @ViewBuilder private var secondaryAction: some View {
        if step == 2 && !calibrating {
            if calibrationNote?.hasPrefix("Calibrated") == true {
                Button("Calibrate Again") { runCalibration() }
            } else {
                Button("Skip for Now") { go(3) }
            }
        }
    }

    private func runCalibration() {
        calibrating = true
        Task {
            calibrationNote = await model.calibrate(nil)
            calibrating = false
        }
    }
}

// MARK: Pieces

private struct StepText: View {
    let title: String
    let text: String
    let note: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 26, weight: .semibold).width(.expanded))
                .accessibilityAddTraits(.isHeader)
            Text(text)
                .font(.system(size: 14))
                .fixedSize(horizontal: false, vertical: true)
            Text(note)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .lineSpacing(2)
    }
}

private struct Granted: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)
            .padding(.top, 14)
    }
}

private struct Problem: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Label(text, systemImage: "exclamationmark.circle.fill")
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 14)
    }
}

private struct Waiting: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).foregroundStyle(.secondary)
        }
        .padding(.top, 14)
    }
}

/// The user's displays, drawn to scale on the night ground, with the gleam resting on one.
private struct Stage: View {
    let displays: [DisplayInfo]
    let step: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let rects = Self.layout(displays, in: CGRect(x: 40, y: 44, width: geo.size.width - 80, height: geo.size.height - 84))
            let target = Self.target(for: step, displays: displays)
            ZStack(alignment: .topLeading) {
                Color(nsColor: Palette.night)
                RadialGradient(colors: [Color(nsColor: Palette.dusk).opacity(0.75), .clear],
                               center: .center, startRadius: 0, endRadius: geo.size.width * 0.55)
                ForEach(rects.indices, id: \.self) { i in
                    let r = rects[i]
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(nsColor: Palette.dusk).opacity(i == target ? 1 : 0.55))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color(nsColor: Palette.mist).opacity(i == target ? 0.6 : 0.25), lineWidth: 1))
                        .frame(width: r.width, height: r.height)
                        .position(x: r.midX, y: r.midY)
                }
                if rects.indices.contains(target) {
                    Circle()
                        .fill(Color(nsColor: Palette.gleam))
                        .frame(width: 12, height: 12)
                        .shadow(color: Color(nsColor: Palette.gleam).opacity(0.9), radius: 10)
                        .shadow(color: Color(nsColor: Palette.gleam).opacity(0.4), radius: 24)
                        .position(x: rects[target].midX, y: rects[target].midY)
                }
                StepMarks(step: step)
                    .frame(maxWidth: .infinity)
                    .position(x: geo.size.width / 2, y: geo.size.height - 20)
            }
            .animation(reduceMotion ? nil : .spring(response: 0.6, dampingFraction: 0.78), value: step)
        }
    }

    /// Fit the arrangement into `box`, keeping proportions, with a small gap between screens.
    static func layout(_ displays: [DisplayInfo], in box: CGRect) -> [CGRect] {
        let bounds = displays.isEmpty ? [CGRect(x: 0, y: 0, width: 1600, height: 1000)] : displays.map(\.bounds)
        let union = bounds.dropFirst().reduce(bounds[0]) { $0.union($1) }
        let scale = min(box.width / union.width, box.height / union.height)
        let offset = CGPoint(x: box.midX - union.width * scale / 2, y: box.midY - union.height * scale / 2)
        return bounds.map { b in
            CGRect(x: offset.x + (b.minX - union.minX) * scale, y: offset.y + (b.minY - union.minY) * scale,
                   width: b.width * scale, height: b.height * scale).insetBy(dx: 3, dy: 3)
        }
    }

    /// Camera step: the screen with the built-in camera. Then a different screen at each step,
    /// ending on the main display.
    static func target(for step: Int, displays: [DisplayInfo]) -> Int {
        guard displays.count > 1 else { return 0 }
        let builtin = displays.firstIndex(where: \.isBuiltin) ?? 0
        let main = displays.firstIndex(where: { $0.bounds.origin == .zero }) ?? 0
        switch step {
        case 0: return builtin
        case 3: return main
        default: return (builtin + step) % displays.count
        }
    }
}

/// Four marks for the four steps: the current one long and lit.
private struct StepMarks: View {
    let step: Int
    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<4, id: \.self) { i in
                Capsule()
                    .fill(i == step ? Color(nsColor: Palette.gleam) : Color(nsColor: Palette.mist).opacity(i < step ? 0.7 : 0.25))
                    .frame(width: i == step ? 22 : 6, height: 6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(step + 1) of 4")
    }
}
