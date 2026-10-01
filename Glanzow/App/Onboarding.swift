import SwiftUI
import GlanzowKit

/// FR-ONB-01: four steps — camera, Accessibility, calibration, done. Reopened from the menu (FR-ONB-04).
struct OnboardingView: View {
    @ObservedObject var model: AppModel
    @State private var step = 0
    @State private var launchAtLogin = true
    @State private var calibrationNote: String?
    @State private var calibrating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Step \(step + 1) of 4").font(.caption).foregroundStyle(.secondary)
            switch step {
            case 0: cameraStep
            case 1: accessibilityStep
            case 2: calibrationStep
            default: doneStep
            }
            Spacer()
            HStack {
                if step > 0 { Button("Back") { step -= 1 } }
                Spacer()
                if step < 3 {
                    Button(step == 2 && calibrationNote == nil ? "Skip for Now" : "Next") { step += 1 }
                        .disabled(!canAdvance)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Finish") { model.finishOnboarding(launchAtLogin: launchAtLogin) }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 540, height: 380)
        .onAppear { step = !model.cameraAuthorized ? 0 : !model.permissionsGranted ? 1 : step }
        .onChange(of: model.cameraAuthorized) { _, ok in if ok && step == 0 { step = 1 } }
        .onChange(of: model.permissionsGranted) { _, ok in if ok && step == 1 { step = 2 } } // FR-ONB-03 auto-advance
    }

    private var canAdvance: Bool {
        switch step {
        case 0: model.cameraAuthorized
        case 1: model.permissionsGranted
        default: !calibrating
        }
    }

    private func heading(_ s: String) -> some View {
        Text(s).font(.title2.bold()).accessibilityAddTraits(.isHeader)
    }

    private var cameraStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading("Camera")
            Text("Glanzow uses your Mac's camera to see which screen you are facing, then moves keyboard focus there before you type.")
            Text("Frames are processed in memory only. Nothing is saved to disk and nothing is sent over the network. The green camera light stays on whenever tracking runs — that is expected.")
                .foregroundStyle(.secondary)
            if model.cameraAuthorized {
                Label("Camera access granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else if model.cameraDenied {
                Text("Camera access is turned off for Glanzow.")
                Button("Open Camera Settings") { AppModel.openPrivacySettings("Privacy_Camera") }
            } else {
                Button("Allow Camera Access") { Task { await model.requestCamera() } }
            }
        }
    }

    private var accessibilityStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading("Accessibility")
            Text("To bring windows forward and move the pointer, Glanzow needs Accessibility access. It notes only when keys are pressed, never which keys.")
            if model.permissionsGranted {
                Label("Accessibility access granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else if !model.axTrusted {
                Button("Open Accessibility Settings") { model.requestAccessibility() }
                HStack { ProgressView().controlSize(.small); Text("Waiting for permission…").foregroundStyle(.secondary) }
            } else {
                Text("This Mac also needs Input Monitoring so Glanzow can pause while you type.")
                Button("Open Input Monitoring Settings") { model.requestInputMonitoring() }
            }
        }
    }

    private var calibrationStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading("Calibration")
            Text("A dot moves around each screen for about 20 seconds. Turn your head to follow it, the way you would naturally look at that screen. Then look at each screen once more to check the result.")
            Text("Press Escape to cancel at any time.").foregroundStyle(.secondary)
            if calibrating {
                HStack { ProgressView().controlSize(.small); Text("Calibrating…") }
            } else {
                Button(calibrationNote == nil ? "Start Calibration" : "Calibrate Again") {
                    calibrating = true
                    Task {
                        calibrationNote = await model.calibrate(nil)
                        calibrating = false
                    }
                }
                .disabled(!model.permissionsGranted)
            }
            if let calibrationNote { Text(calibrationNote) }
        }
    }

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading("You're set")
            Text("Glanzow lives in the menu bar. Look at a screen and keep looking for a moment: focus moves there. It waits while you type or use the mouse.")
            Text("Pause or resume any time with \(UserDefaults.standard.string(forKey: Pref.hotkeyLabel) ?? "⇧⌘G"). Recalibrate from the menu if you move your laptop or monitors.")
            Toggle("Launch Glanzow at login", isOn: $launchAtLogin)
        }
    }
}
