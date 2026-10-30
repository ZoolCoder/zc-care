import Foundation
import Testing
@testable import ZCCareCore

@Test func fileVaultReadsOnOffAndProgress() {
    #expect(SecurityChecks.fileVault("FileVault is On.\n") == true)
    #expect(SecurityChecks.fileVault("FileVault is Off.\n") == false)
    #expect(SecurityChecks.fileVault("Encryption in progress: Percent completed = 12\nFileVault is On.") == true)
    #expect(SecurityChecks.fileVault("AuthorizationCreate() failed: -60008") == nil)
}

@Test func firewallReadsState() {
    #expect(SecurityChecks.firewall("Firewall is enabled. (State = 1)") == true)
    #expect(SecurityChecks.firewall("Firewall is blocking all non-essential incoming connections. (State = 2)") == true)
    #expect(SecurityChecks.firewall("Firewall is disabled. (State = 0)") == false)
    #expect(SecurityChecks.firewall("") == nil)
}

@Test func integrityCountsOnlyPlainEnabled() {
    #expect(SecurityChecks.integrity("System Integrity Protection status: enabled.\n") == true)
    #expect(SecurityChecks.integrity("System Integrity Protection status: disabled.\n") == false)
    #expect(SecurityChecks.integrity("System Integrity Protection status: unknown (Custom Configuration).\n\nConfiguration:\n\tKext Signing: disabled") == false)
    #expect(SecurityChecks.integrity("System Integrity Protection status: enabled (Custom Configuration).\n") == false)
    #expect(SecurityChecks.integrity("csrutil: failed") == nil)
}

@Test func securityUpdatesDefaultOn() {
    #expect(SecurityChecks.securityUpdates(nil))
    #expect(SecurityChecks.securityUpdates(["CriticalUpdateInstall": 1, "ConfigDataInstall": true]))
    #expect(!SecurityChecks.securityUpdates(["CriticalUpdateInstall": 0]))
    #expect(!SecurityChecks.securityUpdates(["CriticalUpdateInstall": true, "ConfigDataInstall": false]))
}

@Test func checksKeepOrderAndUnknowns() {
    let checks = SecurityChecks.checks(fileVault: "FileVault is On.", firewall: nil, integrity: "System Integrity Protection status: enabled.", updates: nil)
    #expect(checks.map(\.name) == ["FileVault", "Firewall", "System Integrity Protection", "Security Responses"])
    #expect(checks.map(\.on) == [true, nil, true, true])
    #expect(checks[2].pane == nil)
}
