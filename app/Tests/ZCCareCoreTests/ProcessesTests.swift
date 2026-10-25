import Testing
@testable import ZCCareCore

@Suite struct ProcessesTests {
    private func proc(_ pid: Int32 = 500, name: String = "Safari", uid: UInt32? = 501, ppid: Int32? = 1) -> Proc {
        Proc(pid: pid, cpu: 1, memory: 1024, name: name, uid: uid, ppid: ppid)
    }

    @Test func detailedParseReadsOwnerParentAndState() {
        let procs = Proc.parse(ps: " 40387   4.1 826432   501  3000 TN  Google Chrome Helper\n  9  0.0 10 0 1 Z+ ghost\n", detailed: true)
        #expect(procs.count == 2)
        #expect(procs[0].uid == 501 && procs[0].ppid == 3000 && procs[0].name == "Google Chrome Helper" && procs[0].isStopped)
        #expect(procs[1].isZombie && !procs[1].isStopped)
    }

    @Test func plainParseKeepsOldShape() {
        let procs = Proc.parse(ps: "  12 1.0 100 Safari\n")
        #expect(procs.first?.uid == nil && procs.first?.ppid == nil && procs.first?.state == "")
    }

    @Test func detailedParseRejectsBadOwnerOrParent() {
        #expect(Proc.parse(ps: "12 1.0 100 me 1 S Safari\n", detailed: true).isEmpty)
        #expect(Proc.parse(ps: "12 1.0 100 501 S Safari\n", detailed: true).isEmpty)
    }

    @Test func protectsItsOwnChildren() {
        #expect(Processes.protection(of: proc(name: "brew", ppid: 99), uid: 501, pid: 99) != nil)
        #expect(Processes.protection(of: proc(name: "brew", ppid: 98), uid: 501, pid: 99) == nil)
    }

    @Test func protectsSessionDaemonsByExactName() {
        #expect(Processes.protection(of: proc(name: "UserEventAgent"), uid: 501, pid: 99) != nil)
        #expect(Processes.protection(of: proc(name: "usereventagent"), uid: 501, pid: 99) == nil)
    }

    @Test func ordinaryProcessIsAllowed() {
        #expect(Processes.protection(of: proc(), uid: 501, pid: 99) == nil)
        #expect(Processes.protection(of: proc(uid: nil), uid: 501, pid: 99) == nil)
    }

    @Test func protectsSelfAndLowPids() {
        #expect(Processes.protection(of: proc(99), uid: 501, pid: 99) != nil)
        #expect(Processes.protection(of: proc(0), uid: 501, pid: 99) != nil)
        #expect(Processes.protection(of: proc(1), uid: 501, pid: 99) != nil)
    }

    @Test func protectsSystemDaemonsAndOtherUsers() {
        #expect(Processes.protection(of: proc(name: "WindowServer"), uid: 501, pid: 99) != nil)
        #expect(Processes.protection(of: proc(name: "Finder"), uid: 501, pid: 99) != nil)
        #expect(Processes.protection(of: proc(uid: 0), uid: 501, pid: 99) != nil)
    }
}
