import Foundation

public enum Processes {
    /// Daemons the session cannot do without, the user-owned ones included.
    static let systemNames: Set<String> = [
        "kernel_task", "launchd", "WindowServer", "loginwindow", "coreaudiod", "mds", "mds_stores",
        "logd", "cfprefsd", "Dock", "Finder", "SystemUIServer", "ControlCenter", "NotificationCenter",
        "launchservicesd", "UserEventAgent", "distnoted", "pboard", "secd", "trustd", "sharingd",
        "runningboardd", "talagent", "universalaccessd", "lsd", "securityd", "opendirectoryd", "notifyd",
    ]

    /// Why ZC Care offers no Quit for this process, or nil when it may.
    public static func protection(of proc: Proc, uid: UInt32 = getuid(), pid: Int32 = getpid()) -> String? {
        if proc.pid == pid { return "ZC Care cannot quit itself." }
        if proc.pid <= 1 { return "macOS needs this process." }
        if let parent = proc.ppid, parent == pid { return "ZC Care started this process; wait for it or cancel the task." }
        if systemNames.contains(proc.name) { return "\(proc.name) is part of macOS." }
        if let owner = proc.uid, owner != uid { return "Another user owns this process." }
        return nil
    }
}
