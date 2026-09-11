import SwiftUI
import TypesterCore

/// One-click recovery when Accessibility was reset (typically after an ad-hoc signed update).
///
/// Goal: no hunting through System Settings. Open the pane, drag the icon, relaunch.
struct PermissionRecoveryView: View {
    var onDismiss: () -> Void
    var onRelaunch: () -> Void

    @State private var accessibilityGranted = TextPaster.checkAccessibilityPermission()

    private var runsFromAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Rectangle()
                .fill(Codex.hairline)
                .frame(height: 1)

            VStack(alignment: .leading, spacing: 14) {
                Text(accessibilityGranted
                     ? "Access is granted. Relaunch once so Typester can pick it up and start listening for your hotkey again."
                     : "macOS reset Accessibility after this update, so the hotkey and paste stopped working. Fix it once — later updates keep the grant.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Codex.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(alignment: .center, spacing: 14) {
                    DraggableAppIconTile()

                    VStack(alignment: .leading, spacing: 8) {
                        Text("1. Drag the icon into Accessibility")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Codex.text)

                        Text(runsFromAppBundle
                             ? "Drop it on the list in System Settings. No plus button, no file picker."
                             : "Install Typester.app, then drag it into the Accessibility list.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Codex.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)
                }
                .padding(12)
                .background(Codex.charcoal, in: RoundedRectangle(cornerRadius: 10))
                .overlay(HairlineBorder(cornerRadius: 10, color: Color(hex: 0x33363D)))

                HStack(spacing: 8) {
                    Button("Open System Settings") {
                        TextPaster.openAccessibilitySettings()
                        AccessibilityDragHelper.shared.show()
                        accessibilityGranted = TextPaster.checkAccessibilityPermission()
                    }
                    .controlSize(.small)

                    Button("I've granted access") {
                        AccessibilityTrustMonitor.shared.poll()
                        accessibilityGranted = TextPaster.checkAccessibilityPermission()
                    }
                    .controlSize(.small)
                    .disabled(accessibilityGranted)

                    Spacer(minLength: 0)

                    if accessibilityGranted {
                        Button("Relaunch Typester") {
                            onRelaunch()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(Codex.green)
                    }
                }
            }
            .padding(16)

            Rectangle()
                .fill(Codex.hairline)
                .frame(height: 1)

            HStack {
                Spacer()
                Button("Later") {
                    PermissionRecovery.markRecoveryDismissedForSession()
                    onDismiss()
                }
                .controlSize(.small)
            }
            .padding(12)
        }
        .frame(width: 480)
        .background(Codex.background)
        .onAppear {
            accessibilityGranted = TextPaster.checkAccessibilityPermission()
        }
        .onReceive(NotificationCenter.default.publisher(for: .accessibilityTrustChanged)) { note in
            if let trusted = note.object as? Bool {
                accessibilityGranted = trusted
            } else {
                accessibilityGranted = TextPaster.checkAccessibilityPermission()
            }
        }
        .onReceive(Timer.publish(every: 0.75, on: .main, in: .common).autoconnect()) { _ in
            let trusted = TextPaster.checkAccessibilityPermission()
            if trusted != accessibilityGranted {
                accessibilityGranted = trusted
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color(hex: 0xD99431))

            Text("Fix dictation access")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Codex.text)

            Spacer()

            Button {
                PermissionRecovery.markRecoveryDismissedForSession()
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Codex.textTertiary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focuslessButton()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}
