import Foundation

// TailBridge privileged helper. Fixed commands only; no generic execution.
// Usage (root): enable --iface utunN --ip4 A --ip6 B --domain X.ts.net | disable | watch | status
//               | install-daemon | uninstall

setvbuf(stdout, nil, _IOLBF, 0)
umask(0o022)

func out(_ s: String) { print(s) }
func fail(_ s: String) -> Never {
    FileHandle.standardError.write(Data("BŁĄD: \(s)\n".utf8))
    exit(1)
}

guard geteuid() == 0 else { fail("pomocnik musi działać jako root") }

// Refuse to run from anywhere except the protected install location.
func executablePath() -> String? {
    var size: UInt32 = 0
    _NSGetExecutablePath(nil, &size)
    var buf = [CChar](repeating: 0, count: Int(size) + 1)
    guard _NSGetExecutablePath(&buf, &size) == 0, let real = realpath(buf, nil) else { return nil }
    defer { free(real) }
    return String(cString: real)
}
guard executablePath() == Privileged.helperPath else { fail("uruchamiaj tylko z \(Privileged.helperPath)") }
let selfInfo = SafeFiles.info(Privileged.helperPath)
guard selfInfo.kind == .regular, selfInfo.uid == 0, selfInfo.mode & 0o022 == 0, !SafeFiles.hasACL(Privileged.helperPath) else {
    fail("niebezpieczne uprawnienia lub ACL pomocnika")
}
if let why = SafeFiles.untrustedDirReason("/Library/PrivilegedHelperTools", owner: 0) { fail(why) }

struct RealSys: SystemOps {
    func pfctl(_ args: [String]) -> ProcResult { Proc.run("/sbin/pfctl", args, timeout: 15) }
    func interfaces() -> [IfAddr] { Interfaces.snapshot() }
    func flushDNS() -> [String] {
        var w: [String] = []
        if !Proc.run("/usr/bin/dscacheutil", ["-flushcache"], timeout: 10).ok { w.append("dscacheutil -flushcache nie powiódł się") }
        if !Proc.run("/usr/bin/killall", ["-HUP", "mDNSResponder"], timeout: 10).ok { w.append("killall -HUP mDNSResponder nie powiódł się") }
        return w
    }
}

let paths = Paths(base: Privileged.base, resolverDir: "/private/etc/resolver",
                  legacyState: "/private/var/run/codex-vpn-coexist", owner: 0, trustBase: "/")
let engine = Engine(sys: RealSys(), paths: paths)

func flushLog() { for l in engine.drainLog() { out(l) } }

func writeStatus(_ source: String) {
    do { _ = try engine.withLock { try engine.writeStatusLocked(source: source) } } catch { out("UWAGA: zapis status.json: \(error)") }
}

enum ServiceState { case loaded, absent, unknown }

/// `launchctl print` exits 113 with "Could not find service" when the job is not loaded (observed on 27.2).
/// Anything else is not proof of absence.
func monitorService() -> ServiceState {
    let r = Proc.run("/bin/launchctl", ["print", "system/\(Privileged.label)"], timeout: 10)
    if r.ok { return .loaded }
    if !r.timedOut, r.status == 113, (r.out + r.err).contains("Could not find service") { return .absent }
    return .unknown
}

let args = Array(CommandLine.arguments.dropFirst())

switch args.first {
case "enable":
    guard args.count == 9, args[1] == "--iface", args[3] == "--ip4", args[5] == "--ip6", args[7] == "--domain" else {
        fail("użycie: enable --iface utunN --ip4 A --ip6 B --domain X.ts.net")
    }
    let id = Identity(iface: args[2], index: 1, ip4: args[4], ip6: args[6], domain: args[8])
    guard id.fieldsValid else { fail("nieprawidłowe parametry") }
    do {
        try engine.enable(id)
        flushLog(); writeStatus("enable")
        out("WŁĄCZONO: wyjątek PF i resolver zweryfikowane; monitor pilnuje tożsamości \(id.iface).")
    } catch {
        flushLog(); writeStatus("enable")
        fail("\(error)")
    }

case "disable":
    guard args.count == 1 else { fail("użycie: disable") }
    do {
        let t = try engine.teardown(reason: "polecenie Wyłącz", includeLegacy: true)
        flushLog(); writeStatus("disable")
        if t.failed { fail("wyłączanie NIEPEŁNE — szczegóły powyżej; monitor ponawia czyszczenie") }
        if !t.leftovers.isEmpty {
            out("WYŁĄCZONO elementy TailBridge, ale POZOSTAWIONO nierozpoznane: " + t.leftovers.joined(separator: "; "))
            exit(2)
        }
        out("WYŁĄCZONO: wyjątek PF i resolver usunięte i zweryfikowane. Mullvad nie był zmieniany.")
    } catch { flushLog(); fail("\(error)") }

case "status":
    guard args.count == 1 else { fail("użycie: status") }
    do {
        let st = try engine.withLock { try engine.writeStatusLocked(source: "status") }
        out(String(decoding: try Engine.encoder.encode(st), as: UTF8.self))
    } catch { fail("\(error)") }

case "watch":
    guard args.count == 1 else { fail("użycie: watch") }
    out("\(Date()) monitor uruchomiony (co 5 s; tylko usuwa nieaktualne elementy)")
    var previous: [String] = []
    while true {
        autoreleasepool {
            do { _ = try engine.tick() } catch { engine.note("BŁĄD cyklu: \(error)") }
            // Identical consecutive cycles (e.g. a long-failing retry) are logged once.
            let lines = engine.drainLog()
            if lines != previous { for l in lines { out("\(Date()) \(l)") } }
            previous = lines
        }
        sleep(5)
    }

case "install-daemon":
    guard args.count == 1 else { fail("użycie: install-daemon") }
    do {
        try engine.prepare()
        if let why = SafeFiles.untrustedDirReason("/Library/LaunchDaemons", owner: 0) { fail(why) }
        let plistWasAbsent: Bool
        switch SafeFiles.info(Privileged.plistPath).kind {
        case .absent: plistWasAbsent = true
        case .regular:
            guard (try? SafeFiles.read(Privileged.plistPath)) == Privileged.launchdPlist() else {
                fail("\(Privileged.plistPath) ma nierozpoznaną treść; odmowa nadpisania")
            }
            plistWasAbsent = false
        default: fail("\(Privileged.plistPath) nie jest zwykłym plikiem; odmowa")
        }
        try engine.withLock { try engine.clearUninstallMarkerLocked() }
        try SafeFiles.replaceAtomic(Privileged.plistPath, Privileged.launchdPlist(), mode: 0o644)
        _ = Proc.run("/bin/launchctl", ["bootout", "system/\(Privileged.label)"], timeout: 20)
        let b = Proc.run("/bin/launchctl", ["bootstrap", "system", Privileged.plistPath], timeout: 20)
        guard b.ok, monitorService() == .loaded else {
            if plistWasAbsent, monitorService() == .absent, unlink(Privileged.plistPath) == 0 { out("Usunięto plist nieudanej pierwszej instalacji") }
            fail("launchctl bootstrap: \(b.err.trimmingCharacters(in: .whitespacesAndNewlines)) — monitor NIE działa")
        }
        out("ZAINSTALOWANO: \(Privileged.helperPath) i monitor \(Privileged.label). Sieć nie została zmieniona.")
    } catch { fail("\(error)") }

case "uninstall":
    guard args.count == 1 else { fail("użycie: uninstall") }
    do {
        // The whole uninstall runs under the engine lock; the persistent marker makes any
        // enable that is already waiting for the lock refuse afterwards.
        let leftovers: [String] = try engine.withLock {
            try engine.markUninstallingLocked()
            let t = engine.teardownLocked(reason: "odinstalowanie", includeLegacy: false)
            flushLog()
            guard !t.failed else { try? engine.clearUninstallMarkerLocked(); fail("czyszczenie nieudane; monitor pozostaje aktywny") }
            _ = Proc.run("/bin/launchctl", ["bootout", "system/\(Privileged.label)"], timeout: 20)
            switch monitorService() {
            case .absent: break
            case .loaded: try? engine.clearUninstallMarkerLocked(); fail("monitor nadal załadowany po bootout; nic więcej nie usunięto")
            case .unknown: try? engine.clearUninstallMarkerLocked(); fail("nie można potwierdzić zatrzymania monitora; nic więcej nie usunięto")
            }
            var problems: [String] = []
            switch SafeFiles.info(Privileged.plistPath).kind {
            case .absent: break
            case .regular where (try? SafeFiles.read(Privileged.plistPath)) == Privileged.launchdPlist():
                if unlink(Privileged.plistPath) != 0 { problems.append("nie usunięto \(Privileged.plistPath)") }
            default: problems.append("\(Privileged.plistPath) zmieniony — pozostawiony")
            }
            // The lock file and the uninstall marker stay: they keep late enable calls refused.
            for f in [paths.status, paths.rulesFile] where SafeFiles.info(f).kind == .regular {
                if unlink(f) != 0 { problems.append("nie usunięto \(f)") }
            }
            if unlink(Privileged.helperPath) != 0 { problems.append("nie usunięto \(Privileged.helperPath)") }
            if !problems.isEmpty { fail("odinstalowanie NIEPEŁNE: " + problems.joined(separator: "; ")) }
            return t.leftovers
        }
        let summary = Privileged.uninstallSummary(leftovers: leftovers, backups: paths.backups)
        out(summary.line)
        exit(summary.status)
    } catch { fail("\(error)") }

default:
    fail("użycie: enable … | disable | status | watch | install-daemon | uninstall")
}
