import SwiftUI
import AppKit

/// Codex design language tokens for the Typester UI.
///
/// Monochrome surfaces with hairline strokes, one green accent, and
/// monospace type for every value the machine reads back (keys, model IDs,
/// shortcuts, versions). All colors are appearance-adaptive.
enum Codex {
    // MARK: Raw palette

    /// #0E0F12 — primary text on light; deepest surface on dark.
    static let charcoal = Color(hex: 0x0E0F12)
    /// #202123 — elevated cards on dark; insets on light.
    static let slate = Color(hex: 0x202123)
    /// #F5F7FA — light surface; text on dark.
    static let mist = Color(hex: 0xF5F7FA)
    /// #9EA1AA — secondary text on dark; hairlines.
    static let steel = Color(hex: 0x9EA1AA)
    /// #10A37F — the single accent: active controls, success, recording.
    static let green = Color(hex: 0x10A37F)
    /// #2B8FFF — links only.
    static let azure = Color(hex: 0x2B8FFF)
    /// #40434A — strokes and token borders.
    static let graphite = Color(hex: 0x40434A)

    // MARK: Semantic tokens

    /// Primary label text.
    static let text = dynamic(0x0E0F12, 0xF5F7FA)
    /// Secondary label / caption text.
    static let textSecondary = dynamic(0x54575F, 0x9EA1AA)
    /// Tertiary text (footnotes, placeholder).
    static let textTertiary = dynamic(0x8A8D95, 0x6A6D75)

    /// Window content background.
    static let background = dynamic(0xF5F7FA, 0x1A1B20)
    /// Sidebar / rail background.
    static let sidebar = dynamic(0xECEDF1, 0x141519)
    /// Cards and menus on top of the background.
    static let surface = dynamic(0xFFFFFF, 0x202123)
    /// Inset fields and transcript wells.
    static let surfaceInset = dynamic(0xF0F1F5, 0x26272C)

    /// Single-pixel separators.
    static let hairline = dynamic(0xDDE0E6, 0x33363D)
    /// Key-token bottom edge (reads as a keycap).
    static let keycapEdge = dynamic(0xB9BDC7, 0x45484F)

    private static func dynamic(_ lightHex: UInt32, _ darkHex: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [
                .darkAqua,
                .vibrantDark,
                .accessibilityHighContrastDarkAqua,
                .accessibilityHighContrastVibrantDark
            ]) != nil
            return NSColor(hex: isDark ? darkHex : lightHex)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            calibratedRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

// MARK: - Fonts

extension Font {
    /// Monospace for values the machine reads back.
    static func mono(_ size: CGFloat = 12, _ weight: Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - Key token

/// Monospace chip with a keycap bottom edge — the signature treatment for
/// shortcuts, model IDs, versions, and other machine-facing values.
struct KeyToken: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.mono(11.5, .medium))
            .foregroundStyle(Codex.text)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Codex.surfaceInset)
            .overlay(alignment: .bottom) {
                // Heavier bottom edge so the chip reads as a keycap.
                Rectangle()
                    .fill(Codex.keycapEdge)
                    .frame(height: 1.5)
                    .padding(.horizontal, 1)
            }
            .overlay(KeycapBorder())
            .clipShape(CapsuleKeycapShape())
            .fixedSize()
    }
}

/// Rounded rectangle with a slightly squarer radius so tokens read as keys.
struct CapsuleKeycapShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path(roundedRect: rect, cornerRadius: min(5, rect.height / 2 - 1))
    }
}

/// Concrete border views: inline shape `.strokeBorder` is unavailable to
/// macOS 13 targets on newer SDKs (and crashes the beta compiler's
/// diagnostics inside ViewBuilder bodies), so borders ship as views.
struct KeycapBorder: View {
    var body: some View {
        CapsuleKeycapShape().stroke(Codex.hairline, lineWidth: 1)
    }
}

struct HairlineBorder: View {
    var cornerRadius: CGFloat
    var color: Color = Codex.hairline
    var lineWidth: CGFloat = 1

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .stroke(color, lineWidth: lineWidth)
    }
}

// MARK: - Field style

/// Quiet hairline field: inset surface, 1px border that turns green on focus.
struct FieldCard: ViewModifier {
    var focused: Bool = false
    var inset: CGFloat = 9

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, inset)
            .padding(.vertical, 6.5)
            .background(RoundedRectangle(cornerRadius: 7).fill(Codex.surfaceInset))
            .overlay(
                HairlineBorder(
                    cornerRadius: 7,
                    color: focused ? Codex.green : Codex.hairline,
                    lineWidth: focused ? 1.5 : 1
                )
            )
            .animation(.easeOut(duration: 0.12), value: focused)
    }
}

extension View {
    func fieldCard(focused: Bool = false) -> some View {
        modifier(FieldCard(focused: focused))
    }
}

// MARK: - Focusless button style

/// Label-only button style that draws no keyboard-focus ring. The stock
/// `.plain` style outlines a button with an accent-colored rectangle whenever
/// it becomes first responder (e.g. the first sidebar item the moment the
/// settings window opens), and the rectangle stays until focus moves — it
/// reads like a selection that is stuck on screen.
struct FocuslessButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

extension ButtonStyle where Self == FocuslessButtonStyle {
    static var plainFocusless: FocuslessButtonStyle { FocuslessButtonStyle() }
}

// MARK: - Segmented control

/// Minimal segmented control: hairline container, active segment lifts onto
/// the card surface. Used where there are 2–3 mutually exclusive options.
struct CodexSegmented<Option: Hashable>: View {
    let options: [(label: String, value: Option)]
    @Binding var selection: Option

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let isActive = option.value == selection
                Button {
                    selection = option.value
                } label: {
                    Text(option.label)
                        .font(.system(size: 12, weight: isActive ? .medium : .regular))
                        .foregroundStyle(isActive ? Codex.text : Codex.textSecondary)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(isActive ? Codex.surface : Color.clear)
                        )
                        .overlay(
                            HairlineBorder(cornerRadius: 6, color: isActive ? Codex.hairline : Color.clear)
                        )
                }
                .buttonStyle(.plainFocusless)
                .contentShape(Rectangle())
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8).fill(Codex.surfaceInset))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Codex.hairline, lineWidth: 1))
    }
}

// MARK: - Settings scaffolding

/// A titled group of rows separated by hairlines on a card surface.
struct SettingsSection<Content: View>: View {
    let title: String
    let headerLink: (label: String, url: URL)?
    let footer: String?
    private let content: Content

    init(
        _ title: String,
        headerLink: (label: String, url: URL)? = nil,
        footer: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.headerLink = headerLink
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Codex.text)
                Spacer()
                if let headerLink {
                    Link(headerLink.label, destination: headerLink.url)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Codex.azure)
                }
            }
            .padding(.bottom, 4)

            VStack(spacing: 0) { content }
                .background(RoundedRectangle(cornerRadius: 10).fill(Codex.surface))
                .overlay(HairlineBorder(cornerRadius: 10))
                .clipShape(RoundedRectangle(cornerRadius: 10))

            if let footer {
                Text(footer)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Codex.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }
        }
    }
}

/// One control row: leading label, trailing control, hairline underneath.
struct SettingsRow<Control: View>: View {
    let label: String
    let help: String?
    let showsDivider: Bool
    private let control: Control

    init(
        _ label: String,
        help: String? = nil,
        showsDivider: Bool = true,
        @ViewBuilder control: () -> Control
    ) {
        self.label = label
        self.help = help
        self.showsDivider = showsDivider
        self.control = control()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.system(size: 13))
                        .foregroundStyle(Codex.text)
                    if let help {
                        Text(help)
                            .font(.system(size: 11))
                            .foregroundStyle(Codex.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                control
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            if showsDivider {
                Rectangle()
                    .fill(Codex.hairline)
                    .frame(height: 1)
                    .padding(.leading, 14)
            }
        }
    }
}

/// Small status dot: green when granted, amber when pending.
struct StatusDot: View {
    let ok: Bool
    var body: some View {
        Circle()
            .fill(ok ? Codex.green : Color(hex: 0xD99431))
            .frame(width: 7, height: 7)
    }
}
