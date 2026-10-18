import AppKit
import ZCCareCore

/// The questions the app asks before it changes the machine.
@MainActor
enum Alerts {
    /// Lists every change in the plan; deletions get a warning of their own.
    static func confirm(plan: PlanDoc) -> Bool {
        let alert = NSAlert()
        let changes = plan.actions.filter { $0.manual != true }
        alert.messageText = changes.count == 1 ? "Make this change?" : "Make these \(changes.count) changes?"
        let lines = changes.prefix(25).map { "\($0.op)  \($0.resource)" }
        var text = lines.joined(separator: "\n")
        if changes.count > lines.count { text += "\n… and \(changes.count - lines.count) more" }
        if plan.deletes {
            alert.alertStyle = .critical
            text = "This plan deletes things.\n\n" + text
        }
        alert.informativeText = text
        alert.addButton(withTitle: plan.deletes ? "Delete and Apply" : "Apply")
        alert.addButton(withTitle: "Cancel")
        return run(alert) == .alertFirstButtonReturn
    }

    /// The first few items, one a line, and how many more there are, so a
    /// long list does not grow the alert past the screen.
    static func lines(_ items: [String], max: Int = 8) -> String {
        items.prefix(max).joined(separator: "\n") + (items.count > max ? "\nand \(items.count - max) more" : "")
    }

    static func confirm(fix command: String, for title: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Fix \(title)?"
        alert.informativeText = "This runs as administrator, after macOS asks for your password:\n\n\(command)"
        alert.addButton(withTitle: "Fix")
        alert.addButton(withTitle: "Cancel")
        return run(alert) == .alertFirstButtonReturn
    }

    static func confirm(_ title: String, _ text: String, button: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        return run(alert) == .alertFirstButtonReturn
    }

    /// Put Back without Full Disk Access: macOS keeps the Trash closed,
    /// so the way is the Finder's own Put Back, or granting access.
    static func trashClosed(_ title: String) -> PutBackWay? {
        let alert = NSAlert()
        alert.messageText = "Put Back needs Full Disk Access"
        alert.informativeText = "macOS keeps the Trash closed to ZC Care. Show \(title) in the Trash and choose "
            + "File > Put Back in the Finder, or grant Full Disk Access and try again."
        alert.addButton(withTitle: "Show in Trash")
        alert.addButton(withTitle: "Open Privacy Settings")
        alert.addButton(withTitle: "Cancel")
        switch run(alert) {
        case .alertFirstButtonReturn: return .finder
        case .alertSecondButtonReturn: return .grant
        default: return nil
        }
    }

    enum PutBackWay { case finder, grant }

    static func info(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        _ = run(alert)
    }

    /// A menu bar app is never frontmost; the alert must bring it forward.
    private static func run(_ alert: NSAlert) -> NSApplication.ModalResponse {
        NSApp.activate()
        return alert.runModal()
    }
}
