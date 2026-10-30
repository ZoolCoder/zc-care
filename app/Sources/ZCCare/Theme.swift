import AppKit
import SwiftUI

/// Midnight: navy surfaces in every module, cyan for what acts, and
/// colour elsewhere only where it means something: green fine, amber look,
/// red risky. Dark mode whatever the system's is.
enum Theme {
    static let accent = hex(0x42C8F5)
    static let warning = hex(0xF5B544)
    static let good = hex(0x28D99A)
    static let bad = hex(0xFF647A)
    static let violet = hex(0x8D6BFF)
    /// The window's floor and the sidebar's, a step lighter.
    static let floor = hex(0x080F2B)
    static let sidebar = hex(0x10183D)
    static let selected = hex(0x393B82)
    static let card = hex(0x182348).opacity(0.86)
    static let rim = hex(0x29396F)
    static let divider = hex(0x26345C)
    static let radius: CGFloat = 12

    /// The panel's floor, laid behind everything once.
    static var background: some View {
        ZStack {
            LinearGradient(colors: [sidebar, floor], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [violet.opacity(0.18), .clear], center: .topLeading, startRadius: 0, endRadius: 380)
        }
        .drawingGroup()
    }

    static func hex(_ rgb: UInt32) -> Color {
        Color(red: Double(rgb >> 16 & 0xFF) / 255, green: Double(rgb >> 8 & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
    }
}

extension View {
    /// Dark scheme, cyan tint and pill buttons for the whole panel.
    func themed() -> some View {
        environment(\.colorScheme, .dark)
            .tint(Theme.accent)
            .buttonStyle(PillButtonStyle())
            .background(Theme.background)
    }
}

/// A glass card: the tiles, the protection card, the recommendation.
struct Card: ViewModifier {
    var selected = false

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius)
                .strokeBorder(selected ? Theme.accent.opacity(0.8) : Theme.rim))
    }
}

/// Rows grouped on one glass card, as CleanMyMac lists them.
struct ListCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 2) { content }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(Card())
    }
}

/// A white symbol on a gradient rounded square, CleanMyMac's icon look.
struct SymbolTile: View {
    let symbol: String
    let colors: [Color]
    var size: CGFloat = 28

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.27)
        Image(systemName: symbol)
            .font(.system(size: size * 0.48, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(shape.fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)))
            .overlay(shape.strokeBorder(Color.white.opacity(0.2)))
            .shadow(color: (colors.last ?? .clear).opacity(0.45), radius: size / 7, y: 1)
    }
}

/// The gradients SymbolTile is drawn in.
enum Tint {
    static let orange = [Color(red: 1, green: 0.78, blue: 0.35), Color(red: 0.96, green: 0.47, blue: 0.18)]
    static let red = [Color(red: 1, green: 0.5, blue: 0.55), Color(red: 0.86, green: 0.18, blue: 0.32)]
    static let pink = [Color(red: 1, green: 0.55, blue: 0.85), Color(red: 0.84, green: 0.22, blue: 0.62)]
    static let blue = [Color(red: 0.45, green: 0.75, blue: 1), Color(red: 0.2, green: 0.4, blue: 0.95)]
    static let cyan = [Color(red: 0.5, green: 0.92, blue: 1), Color(red: 0.16, green: 0.6, blue: 0.9)]
    static let green = [Color(red: 0.5, green: 0.92, blue: 0.6), Color(red: 0.13, green: 0.66, blue: 0.45)]
    static let violet = [Color(red: 0.7, green: 0.58, blue: 1), Color(red: 0.42, green: 0.26, blue: 0.9)]
    static let gray = [Color(white: 0.62), Color(white: 0.38)]
}

/// A thin rounded bar, filled to value from 0 to 1.
struct Meter: View {
    let value: Double
    let tint: Color

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.1))
                Capsule()
                    .fill(LinearGradient(colors: [tint.opacity(0.65), tint], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(5, g.size.width * min(max(value, 0), 1)))
            }
        }
        .frame(height: 5)
    }
}

/// The panel's default button: a frosted pill with white text.
struct PillButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.controlSize) private var size

    func makeBody(configuration: Configuration) -> some View {
        Pill(configuration: configuration, enabled: enabled, small: size == .small || size == .mini)
    }

    private struct Pill: View {
        let configuration: Configuration
        let enabled: Bool
        let small: Bool
        @State private var over = false

        var body: some View {
            configuration.label
                .font(small ? .caption.weight(.semibold) : .callout.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, small ? 10 : 14)
                .padding(.vertical, small ? 4 : 6)
                .background(RoundedRectangle(cornerRadius: small ? 7 : 9)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.08 : over ? 0.22 : 0.14)))
                .overlay(RoundedRectangle(cornerRadius: small ? 7 : 9).strokeBorder(Color.white.opacity(0.1)))
                .opacity(enabled ? 1 : 0.4)
                .contentShape(Rectangle())
                .onHover { over = $0 && enabled }
        }
    }
}

/// A cyan text link, such as a tile's Free Up.
struct LinkButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Theme.accent.opacity(configuration.isPressed ? 0.6 : enabled ? 1 : 0.4))
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == LinkButtonStyle {
    static var zcLink: LinkButtonStyle { LinkButtonStyle() }
}

/// A square glass button holding one symbol, as in the footer.
struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        IconTile(pressed: configuration.isPressed) { configuration.label }
    }
}

extension ButtonStyle where Self == IconButtonStyle {
    static var icon: IconButtonStyle { IconButtonStyle() }
}

struct IconTile<Label: View>: View {
    var pressed = false
    @ViewBuilder let label: Label
    @Environment(\.isEnabled) private var enabled
    @State private var over = false

    var body: some View {
        label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white.opacity(0.9))
            .frame(width: 28, height: 28)
            .background(RoundedRectangle(cornerRadius: 7)
                .fill(Color.white.opacity(pressed ? 0.06 : over ? 0.2 : 0.12)))
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Rectangle())
            .onHover { over = $0 && enabled }
    }
}

/// The ZoolCoder mark, from the bundle's MenuBarMark.pdf; a run outside the
/// bundle shows a sparkle instead.
enum BrandMark {
    static let template: NSImage = {
        if let url = Bundle.main.url(forResource: "MenuBarMark", withExtension: "pdf"),
           let image = NSImage(contentsOf: url) {
            image.isTemplate = true
            return image
        }
        return NSImage(systemSymbolName: "sparkle", accessibilityDescription: "ZC Care")!
    }()

    static func image(size: CGFloat) -> some View {
        Image(nsImage: template).resizable().renderingMode(.template).frame(width: size, height: size)
    }
}

extension View {
    /// The view, or a spinner in its place while working. The view stays in
    /// the tree under the spinner: on macOS 27 a view that takes a spinner's
    /// place can keep the spinner's spin and draw upside down.
    func spinning(_ working: Bool, size: ControlSize = .small) -> some View {
        opacity(working ? 0 : 1)
            .overlay {
                if working { ProgressView().controlSize(size) }
            }
    }
}
