import Foundation

public enum Grade: String, Sendable {
    case excellent = "Excellent", good = "Good", fair = "Fair", poor = "Needs Care"
}

/// What the Mac tab recommends, with the button that does it.
public struct Advice: Sendable, Equatable {
    public enum Action: Sendable, Equatable {
        case freeUp, memory, cpu, battery, security, updates, none
    }

    public var title: String
    public var body: String
    public var action: Action
    public var button: String?
}

extension Vitals {
    /// What needs care, worst first; each one costs the grade a step.
    /// insecure is the security checks that fail.
    public func concerns(insecure: Int) -> [Advice] {
        var all: [Advice] = []
        if let disk, disk.isLow {
            let left = ByteCountFormatter.string(fromByteCount: disk.available, countStyle: .file)
            all.append(Advice(title: "Your disk is nearly full",
                              body: "Only \(left) left on \(disk.name). Clear caches and build output that come back on their own.",
                              action: .freeUp, button: "Free Up"))
        }
        if let memory, memory.pressure >= 50 {
            all.append(Advice(title: "Memory is under pressure",
                              body: "Apps are competing for memory at \(memory.pressure) %. Quit the ones you are not using.",
                              action: .memory, button: "Top Apps"))
        }
        if insecure > 0 {
            all.append(Advice(title: "\(insecure) security check\(insecure == 1 ? " needs" : "s need") attention",
                              body: "The Health tab shows each one and fixes it.",
                              action: .security, button: "Review"))
        }
        if let sensors, sensors.cpuTemp >= 90 {
            all.append(Advice(title: "Your Mac is running hot",
                              body: "The CPU is at \(Int(sensors.cpuTemp)) °C. See what keeps it busy.",
                              action: .cpu, button: "Top Apps"))
        }
        if let battery, battery.needsService {
            all.append(Advice(title: "Your battery needs service",
                              body: "It holds \(battery.capacity.map { "\($0) %" } ?? "less") of what it held new.",
                              action: .battery, button: "Battery Settings"))
        }
        return all
    }

    public func grade(insecure: Int) -> Grade {
        switch concerns(insecure: insecure).count {
        case 0: .excellent
        case 1: .good
        case 2: .fair
        default: .poor
        }
    }

    /// The worst concern, else pending updates, else that all is well.
    public func advice(insecure: Int, updates: Int) -> Advice {
        if let worst = concerns(insecure: insecure).first { return worst }
        if updates > 0 {
            return Advice(title: "\(updates) update\(updates == 1 ? "" : "s") available",
                          body: "Keep apps, tools and runtimes patched.", action: .updates, button: "Review")
        }
        return Advice(title: "Your Mac is in great shape", body: "Nothing needs care right now.", action: .none)
    }
}
