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
        .overlay {
            if let appBundleURL {
                AppBundleDragSource(bundleURL: appBundleURL)
            } else {
                Color.clear
                    .contentShape(Rectangle())
                    .help("Install Typester.app to drag it into Accessibility")
            }
        }
    }
}

/// AppKit drag source overlaid on the tile.
///
/// SwiftUI's `.onDrag` can only vend `NSItemProvider` data, and the previous
/// implementation (`NSItemProvider(contentsOf:)`) asked macOS to copy the
/// whole `.app` bundle into a temporary directory before the drop target
/// could read it — so the Accessibility entry appeared late or never, and
/// TCC could end up pointing at the temp copy instead of the installed app.
///
/// An AppKit dragging session instead hands over the real bundle URL
/// instantly, carrying the same pasteboard types a Finder drag does
/// (`public.file-url` plus the legacy `NSFilenamesPboardType`), which the
/// System Settings permission lists accept in place.
private final class AppBundleDragSourceView: NSView, NSPasteboardItemDataProvider, NSDraggingSource {
    private static let filenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")

    private let bundleURL: URL

    init(bundleURL: URL) {
        self.bundleURL = bundleURL
        super.init(frame: .zero)
        toolTip = "Drag me into the Accessibility list"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        let item = NSPasteboardItem()
        item.setDataProvider(self, forTypes: [.fileURL, Self.filenamesType])

        let dragItem = NSDraggingItem(pasteboardWriter: item)
        dragItem.setDraggingFrame(bounds, contents: dragImage)

        let session = beginDraggingSession(with: [dragItem], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    func pasteboard(
        _ pasteboard: NSPasteboard?,
        item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        switch type {
        case .fileURL:
            item.setData(bundleURL.dataRepresentation, forType: type)
        case Self.filenamesType:
            item.setPropertyList([bundleURL.path], forType: type)
        default:
            break
        }
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    private var dragImage: NSImage {
        let icon = NSWorkspace.shared.icon(forFile: bundleURL.path)
        icon.size = NSSize(width: 46, height: 46)
        return icon
    }
}

private struct AppBundleDragSource: NSViewRepresentable {
    let bundleURL: URL

    func makeNSView(context: Context) -> AppBundleDragSourceView {
        AppBundleDragSourceView(bundleURL: bundleURL)
    }

    func updateNSView(_ nsView: AppBundleDragSourceView, context: Context) {}
}
