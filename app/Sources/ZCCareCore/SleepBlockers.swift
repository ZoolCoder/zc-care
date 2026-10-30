import Darwin
import Foundation
import IOKit.ps
import IOKit.pwr_mgt

/// A process that stops the Mac, or its screen, from sleeping when idle,
/// from the power assertions it holds.
public struct SleepBlocker: Sendable, Equatable, Identifiable {
    /// The process the assertion is for: caffeinate's client when it holds
    /// one on another's behalf, else the process holding it.
    public var pid: Int32
    public var name: String
    /// The process holding the assertion, when it is not `pid`.
    public var via: String?
    /// Keeps the screen on too, not only the Mac awake.
    public var display: Bool
    public var since: Date?

    public init(pid: Int32, name: String, via: String? = nil, display: Bool, since: Date?) {
        self.pid = pid
        self.name = name
        self.via = via
        self.display = display
        self.since = since
    }

    public var id: Int32 { pid }

    static let systemTypes: Set = ["PreventUserIdleSystemSleep", "PreventSystemSleep", "NoIdleSleepAssertion"]
    static let displayTypes: Set = ["PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion"]

    /// `IOPMCopyAssertionsByProcess` read as pid to assertions. One row per
    /// process the assertions are for, the longest held first. Left out:
    /// assertions turned off (level 0), powerd's own, which only lasts while
    /// the screen is on, kinds that do not stop idle sleep such as
    /// UserIsActive, and PreventSystemSleep on battery, which macOS ignores
    /// there. caffeinate run without `-w` names no client; its parent is.
    public static func parse(_ byProcess: [Int32: [[String: Any]]], onBattery: Bool,
                             name: (Int32) -> String?, parent: (Int32) -> Int32?) -> [SleepBlocker] {
        var found: [SleepBlocker] = []
        for (holder, assertions) in byProcess.sorted(by: { $0.key < $1.key }) {
            for assertion in assertions {
                let type = assertion["AssertType"] as? String ?? ""
                let display = displayTypes.contains(type)
                guard display || systemTypes.contains(type),
                      (assertion["AssertLevel"] as? NSNumber)?.intValue ?? 255 == 255,
                      !(onBattery && type == "PreventSystemSleep") else { continue }
                let process = assertion["Process Name"] as? String ?? name(holder) ?? "pid \(holder)"
                guard process != "powerd" else { continue }
                let client = (assertion["AssertionOnBehalfOfPID"] as? NSNumber)?.int32Value
                let owner = client ?? (process == "caffeinate" ? parent(holder).flatMap { $0 > 1 ? $0 : nil } : nil) ?? holder
                let since = assertion["AssertStartWhen"] as? Date
                if let i = found.firstIndex(where: { $0.pid == owner }) {
                    found[i].display = found[i].display || display
                    if let since, found[i].since.map({ since < $0 }) ?? true { found[i].since = since }
                    // Its own assertion names it better than one held for it.
                    if owner == holder {
                        found[i].name = process
                        found[i].via = nil
                    }
                } else {
                    let ownerName = owner == holder ? process : name(owner) ?? "pid \(owner)"
                    found.append(SleepBlocker(pid: owner, name: ownerName, via: owner == holder ? nil : process,
                                              display: display, since: since))
                }
            }
        }
        return found.sorted { ($0.since ?? .distantFuture, $0.pid) < ($1.since ?? .distantFuture, $1.pid) }
    }

    /// What holds the Mac awake now; nil when powerd does not answer.
    public static func read(name: (Int32) -> String?) -> [SleepBlocker]? {
        var unmanaged: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&unmanaged) == kIOReturnSuccess,
              let dict = unmanaged?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return nil }
        return parse(Dictionary(dict.map { ($0.key.int32Value, $0.value) }, uniquingKeysWith: +), onBattery: onBattery(),
                     name: name, parent: parent)
    }

    private static func onBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (source as String) == kIOPMBatteryPowerKey
    }

    private static func parent(_ pid: Int32) -> Int32? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Int32(info.pbi_ppid)
    }

    /// The short name the kernel keeps for a process; nil when it is gone.
    public static func processName(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// "under 1 min", "for 12 min", "for 3 h 5 min".
    public func held(at now: Date) -> String? {
        guard let since else { return nil }
        let minutes = max(0, Int(now.timeIntervalSince(since) / 60))
        if minutes < 1 { return "under 1 min" }
        return minutes < 60 ? "for \(minutes) min" : "for \(minutes / 60) h \(minutes % 60) min"
    }
}
