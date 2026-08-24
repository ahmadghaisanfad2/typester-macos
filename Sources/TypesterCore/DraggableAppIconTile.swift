import AppKit
import SwiftUI

/// A draggable app-bundle tile for granting Accessibility permission.
///
/// Dropping the tile on Privacy & Security → Accessibility adds Typester
/// directly, so the user never has to hunt for the app with the plus button.
struct DraggableAppIconTile: View {
    /// Real `.app` bundles can be dropped onto System Settings. A `swift run`
    /// binary has no bundle URL worth dragging.
    private var appBundleURL: URL? {
        let url = Bundle.main.bundleURL
        guard url.pathExtension == "app" else { return nil }
        return url
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(Codex.charcoal)

            if appBundleURL != nil {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 36, height: 36)
            } else {
                Image(systemName: "waveform")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Codex.mist)
            }
        }
        .frame(width: 46, height: 46)
        .overlay(HairlineBorder(cornerRadius: 10, color: Color(hex: 0x33363D)))
        .opacity(appBundleURL == nil ? 0.5 : 1)
        .modifier(AppBundleFileDrag(url: appBundleURL))
        .help(appBundleURL == nil
              ? "Install Typester.app to drag it into Accessibility"
              : "Drag me into the Accessibility list")
    }
}

/// Supplies a file-URL item provider, which System Settings accepts as an app to add.
private struct AppBundleFileDrag: ViewModifier {
    let url: URL?

    func body(content: Content) -> some View {
        if let url {
            content.onDrag {
                NSItemProvider(contentsOf: url) ?? NSItemProvider(object: url as NSURL)
            }
        } else {
            content
        }
    }
}
