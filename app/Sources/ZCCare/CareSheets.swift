import AppKit
import SwiftUI
import ZCCareCore

// MARK: Prompts

/// A question the Care window asks in a sheet. The flow that asked waits
/// on the answer; the sheet gives it once, from a button or by closing.
@MainActor
final class Prompt<Body, Answer>: Identifiable {
    let id = UUID()
    let body: Body
    private var answer: ((Answer) -> Void)?

    init(_ body: Body, answer: @escaping (Answer) -> Void) {
        self.body = body
        self.answer = answer
    }

    func reply(_ value: Answer) {
        answer?(value)
        answer = nil
    }
}

/// One item of a review: what goes, where it is, how big it is.
struct ReviewItem: Identifiable {
    var id: String
    var name: String
    var detail: String
    var size: Int64
    var icon: NSImage?

    init(url: URL, size: Int64) {
        id = url.path
        name = url.lastPathComponent
        detail = (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
        self.size = size
        icon = NSWorkspace.shared.icon(forFile: url.path)
    }

    init(_ file: LargeFile) { self.init(url: file.url, size: file.size) }

    init(id: String, name: String, detail: String, size: Int64, icon: NSImage? = nil) {
        self.id = id
        self.name = name
        self.detail = detail
        self.size = size
        self.icon = icon
    }
}

/// What a removal is about to do, listed for a last look.
struct Review {
    var title: String
    /// What stays, or what brings the items back.
    var note: String?
    var items: [ReviewItem]
    var button: String
}

/// Apps that must close before a change, and what the change is.
struct QuitRequest {
    var apps: [NSRunningApplication]
    /// "uninstall Slack", "remove DerivedData": finishes "Quit … to".
    var toDo: String
}

// MARK: Review sheet

struct ReviewSheet: View {
    let prompt: Prompt<Review, Bool>

    var body: some View {
        let review = prompt.body
        let total = review.items.reduce(0) { $0 + $1.size }
        VStack(alignment: .leading, spacing: 12) {
            Text(review.title).font(.title3.weight(.semibold))
            Text("\(Store.counted(review.items.count, "item")), \(Store.bytes(total))" + (review.note.map { ". " + $0 } ?? ""))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(review.items) { item in
                        HStack(spacing: 10) {
                            if let icon = item.icon {
                                Image(nsImage: icon).resizable().frame(width: 24, height: 24)
                            } else {
                                Image(systemName: "doc").frame(width: 24, height: 24).foregroundStyle(.secondary)
                            }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.name).font(.callout).lineLimit(1)
                                Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            Text(Store.bytes(item.size)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                    }
                }
            }
            .frame(maxHeight: 320)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
            HStack {
                Spacer()
                Button("Cancel") { prompt.reply(false) }.keyboardShortcut(.cancelAction)
                Button(review.button) { prompt.reply(true) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        // Escape and the window closing count as Cancel; a reply already given stands.
        .onDisappear { prompt.reply(false) }
    }
}

// MARK: Quit sheet

/// The apps in the way, each with Quit and Force Quit. Closes on its own
/// once the last one is gone.
struct QuitSheet: View {
    let prompt: Prompt<QuitRequest, Bool>
    @State private var running: [NSRunningApplication] = []
    @State private var asked: Set<pid_t> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Quit \(Store.counted(running.count, "app")) to \(prompt.body.toDo)?").font(.title3.weight(.semibold))
            Text("They keep files the change needs. Quit saves your work the usual way; Force Quit ends an app at once and loses unsaved work.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 2) {
                ForEach(running, id: \.processIdentifier) { app in
                    HStack(spacing: 10) {
                        if let icon = app.icon {
                            Image(nsImage: icon).resizable().frame(width: 28, height: 28)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(app.localizedName ?? app.bundleIdentifier ?? "App").font(.callout)
                            if asked.contains(app.processIdentifier) {
                                Text("Asked to quit; still running.").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("Quit") { asked.insert(app.processIdentifier); app.terminate() }.controlSize(.small)
                        Button("Force Quit") { app.forceTerminate() }
                            .controlSize(.small)
                            .help("Ends \(app.localizedName ?? "it") at once; unsaved work is lost.")
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
            }
            HStack {
                Spacer()
                Button("Skip") { prompt.reply(false) }.keyboardShortcut(.cancelAction)
                Button("Quit All") {
                    for app in running { asked.insert(app.processIdentifier); app.terminate() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { running = prompt.body.apps }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                running.removeAll(where: \.isTerminated)
                if running.isEmpty { prompt.reply(true) }
            }
        }
        .onDisappear { prompt.reply(false) }
    }
}

// MARK: Completion sheet

/// How a run went: what went, what stayed and why, and the log to copy.
struct CompletionSheet: View {
    let log: RunLog
    let done: () -> Void
    @State private var copied = false

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: log.allDone ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundStyle(log.allDone ? Theme.good : Theme.warning)
            Text(log.allDone ? "\(log.title): done" : "\(log.title): \(Store.counted(log.failed.count, "item")) stayed")
                .font(.title3.weight(.semibold))
            Text(log.summary).font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(log.lines) { line in
                        HStack(spacing: 8) {
                            Image(systemName: line.done ? "checkmark" : "xmark")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(line.done ? Theme.good : Theme.bad)
                                .frame(width: 14)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(line.name).font(.callout).lineLimit(1)
                                Text(line.failure ?? (line.detail as NSString).abbreviatingWithTildeInPath)
                                    .font(.caption).foregroundStyle(line.done ? .secondary : Theme.bad)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            Text(Store.bytes(line.size)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                    }
                }
            }
            .frame(maxHeight: 260)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
            HStack {
                Button(copied ? "Copied" : "Copy Log") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(log.text, forType: .string)
                    copied = true
                }
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}

// MARK: Picking

/// The checkbox before a row in a list that removes what is picked.
struct PickBox: View {
    let id: String
    @Binding var picked: Set<String>

    var body: some View {
        Toggle("", isOn: Binding(get: { picked.contains(id) },
                                 set: { on in if on { picked.insert(id) } else { picked.remove(id) } }))
            .toggleStyle(.checkbox)
            .labelsHidden()
    }
}

/// The foot of a list with checkboxes: a note, Select All or None, and
/// the button that removes what is picked, with how much that is.
struct PickBar: View {
    let store: Store
    let ids: [String]
    @Binding var picked: Set<String>
    let size: Int64
    var note: String?
    let action: () -> Void

    var body: some View {
        HStack {
            if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Button(picked.count == ids.count ? "Select None" : "Select All") {
                picked = picked.count == ids.count ? [] : Set(ids)
            }
            .controlSize(.small)
            Button(picked.isEmpty ? store.removeButton
                   : (store.deletesPermanently ? "Delete \(picked.count)" : "Move \(picked.count) to Trash")
                       + " (\(Store.bytes(size)))", action: action)
                .controlSize(.small)
                .disabled(picked.isEmpty || store.busy != nil)
        }
        .padding(10)
        .onChange(of: ids) { _, ids in picked.formIntersection(ids) }
    }
}
