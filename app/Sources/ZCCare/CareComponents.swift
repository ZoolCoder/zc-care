import AppKit
import SwiftUI
import ZCCareCore

// MARK: Shared pieces

/// A big glass card, as Smart Care draws its results.
struct Glass: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 20)
                .fill(LinearGradient(colors: [Color.white.opacity(0.13), Color.white.opacity(0.05)],
                                     startPoint: .top, endPoint: .bottom)))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.white.opacity(0.13)))
    }
}

/// The round button at the bottom of a module, in its tint.
struct RoundButton: View {
    let title: String
    var colors = Tint.pink
    var working = false
    let action: () -> Void
    @State private var over = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(Color.white.opacity(0.12)).frame(width: 96, height: 96)
                Circle()
                    .fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
                    .frame(width: 80, height: 80)
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.35)))
                    .shadow(color: (colors.last ?? .clear).opacity(over ? 0.8 : 0.5), radius: over ? 18 : 12)
                Text(title).font(.headline).foregroundStyle(.white).spinning(working)
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { over = $0 }
    }
}

struct CareHeader: View {
    let title: String
    let subtitle: String
    var busy = false
    var action: (title: String, run: () -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.largeTitle.weight(.bold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if busy { ProgressView().controlSize(.small) }
            if let action {
                Button(action.title, action: action.run).disabled(busy)
                    .keyboardShortcut("r")
                    .help("\(action.title) (⌘R)")
            }
        }
        .padding(.top, 40)
        .padding(.horizontal, 28)
        .padding(.bottom, 14)
    }
}

/// What the Store is doing, or what it last did.
struct Toast: View {
    @Bindable var store: Store

    var body: some View {
        let failed = store.message?.failed ?? false
        HStack(spacing: 8) {
            Image(systemName: failed ? "xmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(failed ? Theme.bad : Theme.good)
                .spinning(store.busy != nil)
            Text(store.busy.map { $0 + "…" } ?? store.message?.text ?? "").lineLimit(2)
            if let cancel = store.cancelBusy {
                Button("Cancel", action: cancel).buttonStyle(.zcLink)
            }
            if store.busy == nil, store.message != nil {
                Button { store.message = nil } label: { Image(systemName: "xmark").accessibilityLabel("Dismiss") }.buttonStyle(.plain)
            }
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Capsule().fill(.ultraThinMaterial))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12)))
        .opacity(store.busy == nil && store.message == nil ? 0 : 1)
        .frame(maxWidth: 560)
    }
}

func relativeDate(_ date: Date?) -> String {
    guard let date else { return "no record" }
    return date.formatted(.relative(presentation: .named))
}

struct FileRow: View {
    @Bindable var care: Care
    let file: LargeFile
    var showsFolder = false
    var dateLabel = "modified"
    var flag: String?

    var body: some View {
        let folder = (file.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
        CareRow(icon: Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path)).resizable().frame(width: 32, height: 32),
            title: showsFolder ? folder : file.name,
            detail: (showsFolder ? file.name : folder) + (file.modified.map { " · \(dateLabel) " + relativeDate($0) } ?? ""),
            value: Store.bytes(file.size), flag: flag, flagColor: Theme.good) {
            Button { NSWorkspace.shared.activateFileViewerSelecting([file.url]) } label: {
                Image(systemName: "magnifyingglass").accessibilityLabel("Show in Finder")
            }
            .controlSize(.small)
            .help("Show in Finder")
            Button("Trash") { Task { await care.trash(file) } }.controlSize(.small)
        }
        .contextMenu { IgnoreMenu(store: care.store, url: file.url) }
    }
}

/// A file row's menu: show it, or keep ZC Care away from it for good.
struct IgnoreMenu: View {
    let store: Store
    let url: URL

    var body: some View {
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        Divider()
        Button("Ignore \(url.lastPathComponent)") { store.ignore(url) }
        Button("Ignore Its Folder") { store.ignore(url.deletingLastPathComponent()) }
    }
}

struct CareSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: 0) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.white.opacity(0.1)))
        }
    }
}

struct CareRow<Icon: View, Actions: View>: View {
    let icon: Icon
    let title: String
    let detail: String
    let value: String
    var flag: String?
    var flagColor = Theme.warning
    @ViewBuilder let actions: Actions
    @State private var over = false

    init(icon: Icon, title: String, detail: String, value: String, flag: String? = nil, flagColor: Color = Theme.warning,
         @ViewBuilder actions: () -> Actions) {
        self.icon = icon
        self.title = title
        self.detail = detail
        self.value = value
        self.flag = flag
        self.flagColor = flagColor
        self.actions = actions()
    }

    var body: some View {
        HStack(spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(.body.weight(.medium)).lineLimit(1)
                    if let flag {
                        Text(flag).font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(flagColor.opacity(0.25)))
                            .foregroundStyle(flagColor)
                    }
                }
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(value).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            actions
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(over ? 0.06 : 0)))
        .onHover { over = $0 }
    }
}
