import SwiftUI
import GlanzowKit

/// The menu bar panel: a live view of where you're looking, the Hold switch, the eye features,
/// and today's numbers. Left-click the gleam to open it; right-click for the classic menu.
struct GlancePanel: View {
    @ObservedObject var model: AppModel
    @AppStorage(Pref.focusWithinScreen) private var windows = true
    @AppStorage(Pref.eyeBreaks) private var breaks = false
    @AppStorage(Pref.privacyGuard) private var privacy = false
    @AppStorage(Pref.hotkeyLabel) private var holdKey = "⌃⌥H"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                Text("Glanzow").font(.system(size: 15, weight: .semibold).width(.expanded))
                Spacer()
                StatusPill(status: model.status)
            }

            ScreenStage(displays: model.displays, lit: model.live.display, gleam: model.live.gaze,
                        showsGleam: model.live.display != nil, padding: EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))
                .frame(height: 138)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityElement()
                .accessibilityLabel(liveDescription)

            HoldSwitch(holding: model.userPaused, shortcut: holdKey) { model.userPaused.toggle() }

            HStack(spacing: 8) {
                FeatureTile(title: "Windows & panes", symbol: "rectangle.split.2x1", isOn: $windows)
                FeatureTile(title: "Eye breaks", symbol: "leaf", isOn: $breaks)
                FeatureTile(title: "Privacy guard", symbol: "shield.lefthalf.filled", isOn: $privacy)
            }

            Divider()

            HStack(spacing: 10) {
                Button("Teach My Screens…") { Task { await model.calibrate(nil) } }
                Spacer()
                Button("Settings…") { model.showSettings() }
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    .help("Quit Glanzow")
                    .accessibilityLabel("Quit Glanzow")
            }
            .controlSize(.small)

            Text(model.todayLine).font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 320)
    }

    private var liveDescription: String {
        guard let key = model.live.display, let d = model.displays.first(where: { $0.key == key }) else {
            return "Live view. Glanzow can't see where you're looking right now."
        }
        return "Live view. You're looking at \(d.name)."
    }
}

private struct StatusPill: View {
    let status: AppModel.Status

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(status.tint).frame(width: 7, height: 7)
            Text(status.short).font(.system(size: 12, weight: .medium))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(status.title)
    }
}

private struct HoldSwitch: View {
    let holding: Bool
    let shortcut: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: holding ? "play.fill" : "pause.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(holding ? Color.accentColor : Color.primary.opacity(0.08)))
                    .foregroundStyle(holding ? Color.white : Color.primary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(holding ? "Follow me again" : "Hold focus here").font(.system(size: 13, weight: .semibold))
                    Text(holding ? "Focus is staying where it is" : "Until you resume")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                Spacer()
                Text(shortcut)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.18)))
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(holding ? "Follow me again" : "Hold focus here")
        .accessibilityHint("Shortcut \(shortcut)")
    }
}

private struct FeatureTile: View {
    let title: String
    let symbol: String
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                    .frame(height: 16)
                Text(title).font(.system(size: 11.5, weight: .medium)).lineLimit(2).multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 62, alignment: .topLeading)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isOn ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isOn ? Color.accentColor.opacity(0.35) : Color.clear))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }
}
