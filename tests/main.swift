import Foundation

// Deterministic fixture tests. No real /etc, PF, VPN or network access.

var failures = 0
var passes = 0
func check(_ cond: @autoclosure () -> Bool, _ msg: String, line: Int = #line) {
    if cond() { passes += 1 } else { failures += 1; print("FAIL [\(line)]: \(msg)") }
}
func section(_ s: String) { print("— \(s)") }

final class FakeSys: SystemOps {
    var anchors: [String: [String]] = ["mullvad": ["block drop out quick all"]]
    var main = ["scrub-anchor \"com.apple/*\" all fragment reassemble", "anchor \"com.apple/*\" all", "anchor \"mullvad\" all"]
    var pfOn = true
    /// Raw `pfctl -s info` output instead of the pfOn-derived one.
    var infoOut: String?
    /// Every pfctl call exits 0 with empty output (what a descriptor-starved Proc.run used to return).
    var allEmpty = false
    var addrs: [IfAddr] = []
    /// How the fake kernel prints a loaded rule. Default models `flags any` → no flags token.
    var printTransform: (String) -> String = { $0.replacingOccurrences(of: " flags any no state", with: " no state") }
    var failLoad = false
    var failFlush: Set<String> = []
    var failRead: Set<String> = []
    var flushes = 0
    /// Test hook run before each pfctl call (to inject failures at an exact step).
    var onPfctl: (([String]) -> Void)?

    private func ok(_ s: String) -> ProcResult { ProcResult(status: 0, out: s, err: "") }
    private let bad = ProcResult(status: 1, out: "", err: "pfctl: simulated failure")

    func pfctl(_ a: [String]) -> ProcResult {
        onPfctl?(a)
        if allEmpty { return ok("") }
        if a == ["-s", "info"], let raw = infoOut { return ok(raw) }
        if a == ["-s", "info"] { return ok(pfOn ? "Status: Enabled for 0 days 01:00:00\n" : "Status: Disabled\n") }
        if a == ["-sr"] { return ok(main.joined(separator: "\n") + "\n") }
        guard a.count >= 3, a[0] == "-a" else { return bad }
        let name = a[1]
        switch Array(a.dropFirst(2)) {
        case ["-sr"]:
            return failRead.contains(name) ? bad : ok((anchors[name] ?? []).joined(separator: "\n"))
        case ["-F", "rules"]:
            if failFlush.contains(name) { return bad }
            anchors[name] = []; return ok("")
        default:
            guard a.count == 4, a[2] == "-f", !failLoad,
                  let text = try? String(contentsOfFile: a[3], encoding: .utf8) else { return bad }
            anchors[name] = text.split(separator: "\n").map { printTransform(String($0)) }
            return ok("")
        }
    }
    func interfaces() -> [IfAddr] { addrs }
    func flushDNS() -> [String] { flushes += 1; return [] }
}

let ID = Identity(iface: "utun4", index: 20, ip4: "100.101.102.103", ip6: "fd7a:115c:a1e0::1234", domain: "example-tail.ts.net")

func goodAddrs(_ iface: String = "utun4", index: UInt32 = 20) -> [IfAddr] {
    [IfAddr(name: "en0", index: 6, family: AF_INET, address: "192.168.1.10", up: true),
     IfAddr(name: "utun9", index: 25, family: AF_INET, address: "10.64.0.2", up: true),
     IfAddr(name: iface, index: index, family: AF_INET, address: ID.ip4, up: true),
     IfAddr(name: iface, index: index, family: AF_INET6, address: "fe80::1", up: true),
     IfAddr(name: iface, index: index, family: AF_INET6, address: ID.ip6, up: true)]
}

let legacyRules = [
    "pass out quick on utun4 inet from any to 100.64.0.0/10 flags S/SA no state",
    "pass in quick on utun4 inet from 100.64.0.0/10 to any flags S/SA no state",
    "pass out quick on utun4 inet6 from any to fd7a:115c:a1e0::/48 flags S/SA no state",
    "pass in quick on utun4 inet6 from fd7a:115c:a1e0::/48 to any flags S/SA no state",
]

struct World {
    let root: String
    let sys = FakeSys()
    let paths: Paths
    let engine: Engine
    init() {
        var t = Array("\(NSTemporaryDirectory())tbtest.XXXXXX".utf8CString)
        let p = mkdtemp(&t)!
        let real = URL(fileURLWithPath: String(cString: p)).resolvingSymlinksInPath().path
        root = real
        for d in ["/run", "/resolver"] { mkdir(real + d, 0o755) }
        paths = Paths(base: real + "/TailBridge", resolverDir: real + "/resolver",
                      legacyState: real + "/run/codex-vpn-coexist", owner: getuid(), trustBase: real)
        sys.addrs = goodAddrs()
        engine = Engine(sys: sys, paths: paths)
    }
    var resolverPath: String { paths.resolver(ID.domain) }
    func write(_ path: String, _ s: String) { try! s.write(toFile: path, atomically: false, encoding: .utf8) }
    func read(_ path: String) -> String? { try? String(contentsOfFile: path, encoding: .utf8) }
    func backups() -> [String] { (try? FileManager.default.contentsOfDirectory(atPath: paths.backups)) ?? [] }
    func cleanup() { try? FileManager.default.removeItem(atPath: root) }
}

// MARK: - Validation and injection

section("walidacja")
check(Validate.tailscaleIPv4("100.64.0.1"), "100.64.0.1 ok")
check(Validate.tailscaleIPv4("100.127.255.255"), "górna granica")
for bad in ["100.100.100.100", "100.128.0.1", "100.63.255.255", "100.64.0.999", "100.064.0.1", "100.64.0.1 ",
            "100.64.0.1;id", "100.64.0.1\n", "１００.64.0.1", "100.64.0", "", "100.64.0.1/32", "$(id)"] {
    check(!Validate.tailscaleIPv4(bad), "odrzuca IPv4 \(bad.debugDescription)")
}
check(Validate.tailscaleIPv6("fd7a:115c:a1e0::1234"), "IPv6 ok")
for bad in ["fd7a:115c:a1e1::1", "FD7A:115C:A1E0::1", "fd7a:115c:a1e0:0::1", "fd7a:115c:a1e0::1/48",
            "fd7a:115c:a1e0::1%utun4", "fd7a:115c:a1e0::1 ", "::1", "fd7a:115c:a1e0::g"] {
    check(!Validate.tailscaleIPv6(bad), "odrzuca IPv6 \(bad.debugDescription)")
}
check(Validate.utun("utun4") && Validate.utun("utun0") && Validate.utun("utun1234"), "utun ok")
for bad in ["utun", "utun04", "utun4 ", "en0", "utun4;", "utun12345", "UTUN4", "utun-1"] {
    check(!Validate.utun(bad), "odrzuca iface \(bad.debugDescription)")
}
check(Validate.tailnetDomain("tail1a2b3.ts.net") && Validate.tailnetDomain("example-tail.ts.net"), "domena ok")
for bad in ["ts.net", "a..ts.net", "x.ts.net.evil", "../x.ts.net", "x/ts.net", "-x.ts.net", "X.ts.net", "x.ts.net\n", "x y.ts.net"] {
    check(!Validate.tailnetDomain(bad), "odrzuca domenę \(bad.debugDescription)")
}
check(Validate.port("22") == 22 && Validate.port("65535") == 65535, "port ok")
check(Validate.port("0") == nil && Validate.port("65536") == nil && Validate.port("022") == nil && Validate.port("22 ") == nil, "port zły")
var badID = ID; badID.iface = "utun4; rm -rf /"
check(!badID.fieldsValid && Privileged.enableCommand(badID) == nil, "enableCommand odrzuca wstrzyknięcie")

section("polecenia administratora")
let cmd = Privileged.enableCommand(ID)!
check(cmd == "'/Library/PrivilegedHelperTools/com.tailbridge.helper' 'enable' '--iface' 'utun4' '--ip4' '100.101.102.103' '--ip6' 'fd7a:115c:a1e0::1234' '--domain' 'example-tail.ts.net'", "dokładne polecenie enable")
check(Privileged.shQuote("a'b") == "'a'\\''b'", "cytowanie apostrofu")
check(Privileged.appleScriptString("a\"b\\c") == "\"a\\\"b\\\\c\"", "cytowanie AppleScript")
check(Privileged.installCommand(source: "/x/y", sha256: "zz") == nil, "install wymaga SHA-256")
let inst = Privileged.installCommand(source: "/Apps/My \"Tail\" 'Bridge'.app/Contents/Resources/h", sha256: String(repeating: "a", count: 64))!
check(inst.contains("/bin/cat '/Apps/My \"Tail\" '\\''Bridge'\\''.app/Contents/Resources/h'"), "ścieżka źródła zacytowana")
check(inst.contains("if '/Library/PrivilegedHelperTools/com.tailbridge.helper' install-daemon") && !inst.contains("/Apps/My \"Tail\" '\\''Bridge'\\''.app/Contents/Resources/h' install-daemon"), "uruchamiana tylko chroniona kopia")

// MARK: - PF rules

section("reguły PF")
let r = PFRules.rules(ID)
check(r.count == 4 && r.allSatisfy { $0.hasSuffix(" flags any no state") }, "jawne flags any no state")
check(r[0] == "pass out quick on utun4 inet from 100.101.102.103 to 100.64.0.0/10 flags any no state", "reguła 1 dokładna")
check(r[1] == "pass in quick on utun4 inet from 100.64.0.0/10 to 100.101.102.103 flags any no state", "reguła 2 dokładna")
check(r[2] == "pass out quick on utun4 inet6 from fd7a:115c:a1e0::1234 to fd7a:115c:a1e0::/48 flags any no state", "reguła 3 dokładna")
check(r[3] == "pass in quick on utun4 inet6 from fd7a:115c:a1e0::/48 to fd7a:115c:a1e0::1234 flags any no state", "reguła 4 dokładna")
check(!r.contains { $0.contains(" any to") || $0.contains("to any") }, "brak 'any' jako adresu")
let exp = PFRules.expectedPrinted(ID)
check(PFRules.classify(printed: exp.reversed(), expected: exp) == .exact, "kolejność nieistotna")
check(PFRules.classify(printed: exp.map { $0.replacingOccurrences(of: " no state", with: " flags S/SA no state") }, expected: exp) == .mismatch,
      "flags S/SA to niezgodność (bez sed)")
check(PFRules.classify(printed: exp + ["pass all"], expected: exp) == .mismatch, "dodatkowa reguła = niezgodność")
check(PFRules.classify(printed: Array(exp.prefix(3)), expected: exp) == .mismatch, "brak reguły = niezgodność")
check(PFRules.classify(printed: [], expected: exp) == .empty, "pusty")
check(PFRules.legacyInterface(legacyRules) == "utun4", "rozpoznaje prototyp (flags S/SA)")
check(PFRules.legacyInterface(legacyRules.map { $0.replacingOccurrences(of: " flags S/SA", with: "") }) == "utun4", "rozpoznaje prototyp bez flag")
var mixed = legacyRules; mixed[1] = mixed[1].replacingOccurrences(of: "utun4", with: "utun5")
check(PFRules.legacyInterface(mixed) == nil, "różne utun = nierozpoznany")
check(PFRules.legacyInterface(legacyRules + ["pass all"]) == nil, "dodatkowa reguła = nierozpoznany")
check(PFRules.legacyInterface([legacyRules[0], legacyRules[0], legacyRules[2], legacyRules[3]]) == nil, "duplikat = nierozpoznany")
check(PFRules.appleBeforeMullvad(["anchor \"com.apple/*\" all", "anchor \"mullvad\" all"]), "kolejność ok")
check(!PFRules.appleBeforeMullvad(["anchor \"mullvad\" all", "anchor \"com.apple/*\" all"]), "zła kolejność")
check(!PFRules.appleBeforeMullvad(["anchor \"com.apple/*\" all"]), "brak mullvad")

// MARK: - Interface identity

section("tożsamość interfejsu")
check(Interfaces.problem(ID, in: goodAddrs()) == nil, "zgodna tożsamość")
check(Interfaces.locate(ip4: ID.ip4, ip6: ID.ip6, in: goodAddrs())! == ("utun4", 20), "lokalizacja")
check(Interfaces.problem(ID, in: goodAddrs("utun5", index: 21)) != nil, "adresy przeniesione na utun5")
check(Interfaces.problem(ID, in: goodAddrs(index: 33)) != nil, "nowy indeks")
var reassigned = goodAddrs().filter { $0.name != "utun4" }
reassigned.append(IfAddr(name: "utun4", index: 20, family: AF_INET, address: "10.64.0.9", up: true))
check(Interfaces.problem(ID, in: reassigned) != nil, "utun4 przejęty przez inny VPN")
var extra = goodAddrs(); extra.append(IfAddr(name: "utun4", index: 20, family: AF_INET, address: "10.0.0.1", up: true))
check(Interfaces.problem(ID, in: extra) != nil, "dodatkowy IPv4 na utun4")
var dup = goodAddrs(); dup.append(IfAddr(name: "utun7", index: 30, family: AF_INET, address: ID.ip4, up: true))
check(Interfaces.problem(ID, in: dup) != nil && Interfaces.locate(ip4: ID.ip4, ip6: ID.ip6, in: dup) == nil, "duplikat adresu")
check(Interfaces.problem(ID, in: goodAddrs().map { var a = $0; if a.name == "utun4" { a.up = false }; return a }) != nil, "interfejs DOWN")
check(Interfaces.problem(ID, in: []) != nil, "brak interfejsu")
check(Interfaces.tailscaleCandidates(goodAddrs()) == ["utun4"], "kandydaci Tailscale")

// MARK: - Engine

section("enable: sukces i adopcja prototypu")
do {
    let w = World(); defer { w.cleanup() }
    w.sys.anchors[PFRules.legacyAnchor] = legacyRules
    w.write(w.resolverPath, ResolverContent.legacy)
    mkdir(w.paths.legacyState, 0o700)
    w.write(w.paths.legacyState + "/marker", "codex-vpn-coexist-v1\n")
    w.write(w.paths.legacyState + "/interface", "utun4\n")
    var req = ID; req.index = 999   // GUI-provided index is ignored
    do { try w.engine.enable(req) } catch { check(false, "enable rzucił: \(error)") }
    check(w.sys.anchors[PFRules.anchor]!.sorted() == PFRules.expectedPrinted(ID).sorted(), "anchor dokładny")
    check(w.sys.anchors[PFRules.legacyAnchor] == [], "szerokie reguły prototypu usunięte")
    check(w.read(w.resolverPath) == ResolverContent.ours, "resolver nasz")
    let b = w.backups()
    check(b.contains { $0.hasSuffix("resolver-example-tail.ts.net") } && b.contains { $0.hasSuffix("codex-vpn-coexist-state") }, "kopie prototypu: \(b)")
    if let rb = b.first(where: { $0.hasSuffix("resolver-example-tail.ts.net") }) {
        check(w.read(w.paths.backups + "/" + rb) == ResolverContent.legacy, "kopia resolvera ma oryginalną treść")
    }
    check(SafeFiles.info(w.paths.legacyState).kind == .absent, "stan prototypu przeniesiony")
    if case .valid(let d) = w.engine.readDesired() { check(d.index == 20, "indeks z getifaddrs, nie z GUI") } else { check(false, "brak zamiaru") }
    let st = try! w.engine.tick()
    check(st.enabled && st.anchor == "exact" && st.resolver == "ours" && st.legacyAnchor == "empty", "tick: stan włączony")
    check(w.sys.anchors[PFRules.anchor]!.count == 4, "tick niczego nie usuwa przy zgodności")

    section("disable")
    let t = try! w.engine.teardown(reason: "test", includeLegacy: true)
    check(t.complete, "teardown kompletny")
    check(!w.engine.cleanupPending, "znacznik czyszczenia usunięty")
    check(w.sys.anchors[PFRules.anchor] == [], "anchor pusty")
    check(SafeFiles.info(w.resolverPath).kind == .absent, "resolver usunięty")
    check(w.engine.readDesired() == .absent, "zamiar usunięty")
    check(w.sys.anchors["mullvad"] == ["block drop out quick all"], "Mullvad nietknięty")
}

section("enable: odmowy bez zmian")
func refuses(_ name: String, _ setup: (World) -> Void) {
    let w = World(); defer { w.cleanup() }
    setup(w)
    let before = w.sys.anchors
    var threw = false
    do { try w.engine.enable(ID) } catch { threw = true }
    check(threw, "\(name): odmowa")
    check(w.sys.anchors == before, "\(name): PF bez zmian")
    check(w.engine.readDesired() == .absent, "\(name): brak zamiaru")
}
refuses("obcy resolver") { w in w.write(w.resolverPath, "nameserver 1.1.1.1\n") }
refuses("resolver-symlink") { w in symlink("/etc/hosts", w.resolverPath) }
refuses("katalog resolver symlink") { w in rmdir(w.paths.resolverDir); symlink(w.root + "/run", w.paths.resolverDir) }
refuses("katalog resolver zapisywalny") { w in chmod(w.paths.resolverDir, 0o777) }
refuses("nierozpoznany anchor prototypu") { w in w.sys.anchors[PFRules.legacyAnchor] = ["pass all"] }
refuses("PF wyłączony") { w in w.sys.pfOn = false }
refuses("zła kolejność anchorów") { w in w.sys.main = ["anchor \"mullvad\" all", "anchor \"com.apple/*\" all"] }
refuses("pusty anchor Mullvad") { w in w.sys.anchors["mullvad"] = [] }
refuses("adresy na innym utun") { w in w.sys.addrs = goodAddrs("utun5", index: 21) }
refuses("Tailscale zatrzymany") { w in w.sys.addrs = [] }
refuses("katalog stanu symlink") { w in symlink(w.root + "/run", w.paths.base) }
refuses("anchor Mullvad nieczytelny") { w in w.sys.failRead = ["mullvad"] }

section("Mullvad: rozłączenie, blokada i stany przejściowe (polityka pomocnika, Daybreak #2)")
do {
    // The helper checks Mullvad's anchor, not the VPN connection (see Engine.enableLocked). After
    // enable, Mullvad disconnecting, blocking or reconnecting leaves the exception alone: its 4 rules
    // pass only tailnet ranges on utun4, and a teardown would force a new password prompt. The GUI
    // decides what that means for the user (green status only with Mullvad connected; tests/app).
    let w = World(); defer { w.cleanup() }
    try! w.engine.enable(ID)
    let rules = w.sys.anchors[PFRules.anchor]!
    for (name, mv) in [("rozłączony (anchor pusty)", [String]()),
                       ("blokada / lockdown", ["block drop out quick all", "block drop in quick all"]),
                       ("ponownie połączony", ["block drop out quick all"])] {
        w.sys.anchors["mullvad"] = mv
        let st = try! w.engine.tick()
        check(w.sys.anchors[PFRules.anchor] == rules && w.read(w.resolverPath) == ResolverContent.ours && !w.engine.cleanupPending,
              "Mullvad \(name): wyjątek bez zmian, bez czyszczenia")
        check(st.enabled && st.anchor == "exact" && st.problems.isEmpty, "Mullvad \(name): pomocnik zgłasza tylko obserwowany wyjątek")
        check(w.sys.anchors["mullvad"] == mv, "Mullvad \(name): anchor Mullvad nietknięty")
    }
    w.sys.failRead = ["mullvad"]
    let st = try! w.engine.tick()
    check(st.enabled && w.sys.anchors[PFRules.anchor] == rules, "błąd odczytu anchora Mullvad w monitorze: wyjątek bez zmian")
    // Re-enable during a disconnect is refused before anything changes; the working state stays.
    w.sys.failRead = []
    w.sys.anchors["mullvad"] = []
    check((try? w.engine.enable(ID)) == nil, "ponowne enable przy pustym anchorze Mullvad: odmowa")
    check(w.sys.anchors[PFRules.anchor] == rules && w.engine.readDesired() == .valid(Identity(iface: ID.iface, index: 20, ip4: ID.ip4, ip6: ID.ip6, domain: ID.domain)),
          "odmowa nie usuwa działającego stanu")
}
do {
    let w = World(); defer { w.cleanup() }
    w.write(w.resolverPath, "nameserver 1.1.1.1\n")
    _ = try? w.engine.enable(ID)
    check(w.read(w.resolverPath) == "nameserver 1.1.1.1\n", "obcy resolver nietknięty")
}

section("enable: wycofanie po błędzie")
do {
    let w = World(); defer { w.cleanup() }
    w.sys.printTransform = { $0.replacingOccurrences(of: " flags any no state", with: " flags S/SA no state") }
    var threw = false
    do { try w.engine.enable(ID) } catch { threw = true }
    check(threw, "flags S/SA w jądrze → odmowa")
    check(w.sys.anchors[PFRules.anchor] == [], "anchor wycofany")
    check(SafeFiles.info(w.resolverPath).kind == .absent, "resolver nie utworzony")
    check(w.engine.readDesired() == .absent, "zamiar usunięty po pełnym wycofaniu")
}
do {
    let w = World(); defer { w.cleanup() }
    w.sys.failLoad = true
    check((try? w.engine.enable(ID)) == nil, "błąd ładowania → odmowa")
    check(w.engine.readDesired() == .absent, "zamiar usunięty")
}
do {
    let w = World(); defer { w.cleanup() }
    w.sys.anchors[PFRules.legacyAnchor] = legacyRules
    w.sys.failFlush = [PFRules.legacyAnchor]
    w.write(w.resolverPath, ResolverContent.legacy)
    check((try? w.engine.enable(ID)) == nil, "nieudane usunięcie prototypu → odmowa (bez dwóch anchorów)")
    check(w.sys.anchors[PFRules.anchor] == [], "nowy anchor wycofany")
    check(w.sys.anchors[PFRules.legacyAnchor] == legacyRules, "stan prototypu zachowany")
    check(w.read(w.resolverPath) == ResolverContent.legacy, "resolver prototypu przywrócony po wycofaniu")
}

section("kolejność mutacji PF: następny krok dopiero po zakończeniu poprzedniego (Daybreak #4)")
/// Wraps FakeSys. A call matching `gate` blocks until `release` is signalled (after signalling `entered`),
/// and may return `gatedResult` instead (e.g. what Proc.run reports for a killed, timed-out pfctl).
/// Records every begin/end and the highest number of pfctl calls in progress at once.
final class GatedSys: SystemOps {
    let inner: FakeSys
    let tag: String
    let shared: GateLog
    var gate: ([String]) -> Bool = { _ in false }
    var gatedResult: ProcResult?
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    init(_ inner: FakeSys, tag: String, log: GateLog) { self.inner = inner; self.tag = tag; shared = log }
    func pfctl(_ a: [String]) -> ProcResult {
        shared.begin("\(tag) \(a.joined(separator: " "))")
        var r: ProcResult?
        if gate(a) {
            gate = { _ in false }
            entered.signal()
            release.wait()
            r = gatedResult
        }
        let out = r ?? inner.pfctl(a)
        shared.end("\(tag) \(a.joined(separator: " "))")
        return out
    }
    func interfaces() -> [IfAddr] { inner.interfaces() }
    func flushDNS() -> [String] { inner.flushDNS() }
}
final class GateLog {
    private let lock = NSLock()
    private(set) var events: [String] = []
    private var active = 0
    private(set) var maxActive = 0
    func begin(_ e: String) { lock.lock(); events.append("begin " + e); active += 1; maxActive = max(maxActive, active); lock.unlock() }
    func end(_ e: String) { lock.lock(); events.append("end " + e); active -= 1; lock.unlock() }
    func snapshot() -> [String] { lock.lock(); defer { lock.unlock() }; return events }
    func index(_ e: String) -> Int? { snapshot().firstIndex(of: e) }
}
/// True if the engine lock is held by someone else right now (checked from another descriptor, non-blocking).
func lockBusy(_ w: World) -> Bool {
    let fd = open(w.paths.lock, O_RDWR | O_CLOEXEC)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    if flock(fd, LOCK_EX | LOCK_NB) == 0 { flock(fd, LOCK_UN); return false }
    return errno == EWOULDBLOCK
}
/// Waits for `s`; on timeout the suite stops at once, so no fixture is inspected or removed while a worker still runs.
func awaitOrAbort(_ s: DispatchSemaphore, _ what: String, line: Int = #line) {
    if s.wait(timeout: .now() + 30) == .success { passes += 1; return }
    print("FAIL [\(line)]: \(what): brak sygnału w 30 s — przerwano"); exit(1)
}
/// Runs `body` on its own thread; the returned semaphore is signalled when it finishes.
func background(_ body: @escaping () -> Void) -> DispatchSemaphore {
    let done = DispatchSemaphore(value: 0)
    Thread.detachNewThread { body(); done.signal() }
    return done
}
do {
    // A rule load that ends as a killed, timed-out pfctl: the rollback flush starts only after it ended,
    // and a monitor pass (another Engine on the same files, as the watch process) waits for the lock.
    let w = World(); defer { w.cleanup() }
    let log = GateLog()
    let enableSys = GatedSys(w.sys, tag: "enable", log: log), watchSys = GatedSys(w.sys, tag: "watch", log: log)
    let load = ["-a", PFRules.anchor, "-f", w.paths.rulesFile]
    enableSys.gate = { $0 == load }
    enableSys.gatedResult = ProcResult(status: 9, out: "", err: "", timedOut: true)
    let enabler = Engine(sys: enableSys, paths: w.paths), watcher = Engine(sys: watchSys, paths: w.paths)
    var enableThrew = false
    let enableDone = background { do { try enabler.enable(ID) } catch { enableThrew = true } }
    awaitOrAbort(enableSys.entered, "ładowanie reguł rozpoczęte")
    check(lockBusy(w), "w trakcie ładowania blokada silnika jest zajęta")
    let watchDone = background { _ = try? watcher.tick() }
    let during = log.snapshot()
    check(during.last == "begin enable \(load.joined(separator: " "))", "w trakcie ładowania nie rozpoczęto innego kroku: \(during.suffix(2))")
    enableSys.release.signal()
    awaitOrAbort(enableDone, "enable zakończone")
    awaitOrAbort(watchDone, "cykl monitora zakończony")
    let loadEnd = log.index("end enable \(load.joined(separator: " "))") ?? Int.max
    let flush = log.index("begin enable -a \(PFRules.anchor) -F rules") ?? -1
    let watchFirst = log.snapshot().firstIndex { $0.hasPrefix("begin watch") } ?? -1
    check(enableThrew, "nieudane ładowanie → enable zgłasza błąd")
    check(flush > loadEnd, "wycofanie (flush) dopiero po zakończeniu ładowania: load end \(loadEnd), flush \(flush)")
    check(watchFirst > loadEnd, "monitor dopiero po zakończeniu ładowania: \(watchFirst) > \(loadEnd)")
    check(log.maxActive == 1, "nigdy dwa wywołania pfctl naraz (max \(log.maxActive))")
    check(w.sys.anchors[PFRules.anchor] == [] && w.engine.readDesired() == .absent && !w.engine.cleanupPending, "wycofanie kompletne")
}
do {
    // A teardown flush still in progress: a concurrent enable (the next change) starts no pfctl before it ended.
    let w = World(); defer { w.cleanup() }
    try! w.engine.enable(ID)
    let log = GateLog()
    let offSys = GatedSys(w.sys, tag: "disable", log: log), onSys = GatedSys(w.sys, tag: "enable", log: log)
    let flush = ["-a", PFRules.anchor, "-F", "rules"]
    offSys.gate = { $0 == flush }
    let off = Engine(sys: offSys, paths: w.paths), on = Engine(sys: onSys, paths: w.paths)
    var t = Teardown()
    let offDone = background { t = (try? off.teardown(reason: "test", includeLegacy: false)) ?? Teardown(failed: true) }
    awaitOrAbort(offSys.entered, "flush rozpoczęty")
    check(lockBusy(w), "w trakcie flush blokada silnika jest zajęta")
    let onDone = background { _ = try? on.enable(ID) }
    check(log.snapshot().last == "begin disable \(flush.joined(separator: " "))", "w trakcie flush nie rozpoczęto innego kroku")
    offSys.release.signal()
    awaitOrAbort(offDone, "wyłączenie zakończone")
    awaitOrAbort(onDone, "kolejne enable zakończone")
    let flushEnd = log.index("end disable \(flush.joined(separator: " "))") ?? Int.max
    let onFirst = log.snapshot().firstIndex { $0.hasPrefix("begin enable") } ?? -1
    check(t.complete, "wyłączenie kompletne")
    check(onFirst > flushEnd, "kolejna zmiana dopiero po zakończeniu flush: \(onFirst) > \(flushEnd)")
    check(log.maxActive == 1, "nigdy dwa wywołania pfctl naraz (max \(log.maxActive))")
}
do {
    // Proc side of the contract, with a harmless process: after a timeout, run returns only once the child
    // (which ignores SIGTERM, so it needs SIGKILL) is confirmed gone and reaped. If SIGTERM arrived before
    // the shell installed its trap (status SIGTERM), that run did not exercise SIGKILL: retry with more time.
    var r = ProcResult(status: -1, out: "", err: "")
    for limit in [0.5, 2.0, 5.0] {
        r = Proc.run("/bin/sh", ["-c", "trap '' TERM; echo $$; exec /bin/sleep 30"], timeout: limit)
        if r.status != SIGTERM { break }
    }
    check(r.timedOut && !r.ok && r.status == SIGKILL, "przekroczenie czasu, proces zakończony dopiero przez SIGKILL: \(r.status)")
    if let pid = r.lines.first.flatMap({ pid_t($0) }) {
        check(kill(pid, 0) == -1 && errno == ESRCH, "po powrocie run proces już nie istnieje (zakończony i zebrany)")
    } else { check(false, "brak pid w wyjściu: \(r.out.debugDescription)") }
}

section("teardown: częściowa awaria i ponawianie")
let enabledID: Identity = { var i = ID; i.index = 20; return i }()
do {
    // Review #3: failed disable must be retried by the monitor even though identity still matches.
    let w = World(); defer { w.cleanup() }
    try! w.engine.enable(ID)
    w.sys.failFlush = [PFRules.anchor]
    let t = try! w.engine.teardown(reason: "test", includeLegacy: true)
    check(t.failed && !t.complete, "teardown zgłasza porażkę")
    check(w.engine.cleanupPending, "znacznik czyszczenia zapisany")
    check(w.engine.readDesired() == .valid(enabledID), "zamiar zachowany do ponowienia")
    check(w.engine.log.contains { $0.contains("BŁĄD") }, "błąd w logu")
    let st = try! w.engine.tick()
    check(!st.enabled && st.cleanupPending, "w trakcie awarii: nie raportuje włączenia")
    w.sys.failFlush = []
    _ = try! w.engine.tick()   // interface unchanged on purpose
    check(w.sys.anchors[PFRules.anchor] == [] && w.engine.readDesired() == .absent && !w.engine.cleanupPending,
          "monitor ponowił czyszczenie mimo zgodnej tożsamości")
}
do {
    // Review #3b: legacy flush fails during enable and own flush fails during rollback.
    let w = World(); defer { w.cleanup() }
    w.sys.anchors[PFRules.legacyAnchor] = legacyRules
    w.write(w.resolverPath, ResolverContent.legacy)
    w.sys.failFlush = [PFRules.legacyAnchor, PFRules.anchor]
    check((try? w.engine.enable(ID)) == nil, "podwójna awaria → odmowa")
    check(w.engine.cleanupPending, "czyszczenie zaległe")
    check(w.read(w.resolverPath) == ResolverContent.legacy, "resolver prototypu przywrócony")
    w.sys.failFlush = []
    _ = try! w.engine.tick()
    check(w.sys.anchors[PFRules.anchor] == [], "po ustąpieniu błędu nowy anchor usunięty")
    check(w.sys.anchors[PFRules.legacyAnchor] == legacyRules, "stan sprzed włączenia (tylko prototyp) zachowany")
    check(!w.engine.cleanupPending, "czyszczenie zakończone")
}
do {
    // Review #4: legacy anchor read error during disable is a failure, not success.
    let w = World(); defer { w.cleanup() }
    w.sys.anchors[PFRules.legacyAnchor] = legacyRules
    w.sys.failRead = [PFRules.legacyAnchor]
    let t = try! w.engine.teardown(reason: "test", includeLegacy: true)
    check(t.failed, "błąd odczytu prototypu = porażka")
    w.sys.failRead = []
    _ = try! w.engine.tick()
    check(w.sys.anchors[PFRules.legacyAnchor] == [] && !w.engine.cleanupPending, "monitor dokończył usuwanie prototypu")
}
do {
    let w = World(); defer { w.cleanup() }
    w.sys.anchors[PFRules.legacyAnchor] = ["pass all"]
    let t = try! w.engine.teardown(reason: "test", includeLegacy: true)
    check(!t.failed && !t.leftovers.isEmpty && !t.complete, "nierozpoznany prototyp = pozostawiony, zgłoszony")
    check(w.sys.anchors[PFRules.legacyAnchor] == ["pass all"] && !w.engine.cleanupPending, "nietknięty, bez nieskończonego ponawiania")
}
do {
    let w = World(); defer { w.cleanup() }
    try! w.engine.enable(ID)
    w.write(w.resolverPath, "# edited by user\nnameserver 100.100.100.100\n")
    let t = try! w.engine.teardown(reason: "test", includeLegacy: false)
    check(!t.failed && t.leftovers.count == 1, "zmieniony resolver = pozostawiony i zgłoszony")
    check(w.read(w.resolverPath) == "# edited by user\nnameserver 100.100.100.100\n", "zmieniony resolver nietknięty")
}
do {
    // Review #7: teardown must not follow a symlinked resolver directory.
    let w = World(); defer { w.cleanup() }
    try! w.engine.enable(ID)
    let elsewhere = w.root + "/elsewhere"
    mkdir(elsewhere, 0o755)
    w.write(elsewhere + "/" + ID.domain, ResolverContent.ours)
    rename(w.paths.resolverDir, w.root + "/resolver-moved")
    symlink(elsewhere, w.paths.resolverDir)
    let t = try! w.engine.teardown(reason: "test", includeLegacy: false)
    check(t.failed, "katalog resolverów jako symlink = porażka")
    check(w.read(elsewhere + "/" + ID.domain) == ResolverContent.ours, "plik poza katalogiem nietknięty")
}
do {
    // Review #6: a failing re-enable must not destroy a working state.
    let w = World(); defer { w.cleanup() }
    try! w.engine.enable(ID)
    w.sys.failLoad = true
    check((try? w.engine.enable(ID)) != nil, "ponowne włączenie tej samej tożsamości: bez zmian")
    check(w.sys.anchors[PFRules.anchor]!.count == 4 && w.read(w.resolverPath) == ResolverContent.ours
          && w.engine.readDesired() == .valid(enabledID), "działający stan zachowany")
}

do {
    // Re-review #8: a long-failing retry must not grow the marker.
    let w = World(); defer { w.cleanup() }
    try! w.engine.enable(ID)
    w.sys.failFlush = [PFRules.anchor]
    _ = try! w.engine.teardown(reason: "test", includeLegacy: false)
    let size1 = (try? SafeFiles.read(w.paths.cleanup))?.utf8.count ?? -1
    for _ in 0..<5 { _ = try! w.engine.tick() }
    let size2 = (try? SafeFiles.read(w.paths.cleanup))?.utf8.count ?? -2
    check(size1 > 0 && size1 == size2, "znacznik nie rośnie przy ponowieniach (\(size1) → \(size2))")
}
do {
    // Re-review #2: uninstall marker makes a waiting enable refuse.
    let w = World(); defer { w.cleanup() }
    try! w.engine.withLock { try w.engine.markUninstallingLocked() }
    check((try? w.engine.enable(ID)) == nil, "enable po odinstalowaniu odrzucone")
    check(w.sys.anchors[PFRules.anchor] == nil && w.engine.readDesired() == .absent, "nic nie utworzono")
    try! w.engine.withLock { try w.engine.clearUninstallMarkerLocked() }
    check((try? w.engine.enable(ID)) != nil, "po ponownej instalacji enable działa")
}
do {
    // Daybreak #5: uninstall keeps an edited resolver, and its summary names it (status 2, not plain success).
    let w = World(); defer { w.cleanup() }
    try! w.engine.enable(ID)
    let edited = "# edited by user\nnameserver 1.1.1.1\n"
    w.write(w.resolverPath, edited)
    let t = try! w.engine.withLock { () -> Teardown in
        try w.engine.markUninstallingLocked()
        return w.engine.teardownLocked(reason: "odinstalowanie", includeLegacy: false)
    }
    check(!t.failed && t.leftovers.count == 1 && t.leftovers[0].hasPrefix(w.resolverPath), "odinstalowanie: zmieniony resolver zgłoszony: \(t.leftovers)")
    check(w.read(w.resolverPath) == edited, "odinstalowanie: obcy plik zachowany bez zmian")
    check(w.sys.anchors[PFRules.anchor] == [] && w.engine.readDesired() == .absent && !w.engine.cleanupPending, "odinstalowanie: własne elementy usunięte")
    let partial = Privileged.uninstallSummary(leftovers: t.leftovers, backups: w.paths.backups)
    check(partial.status == 2 && partial.line.contains("POZOSTAWIONO") && partial.line.contains(w.resolverPath),
          "podsumowanie: kod 2 i ścieżka pozostawionego pliku: \(partial)")
    let clean = Privileged.uninstallSummary(leftovers: [], backups: w.paths.backups)
    check(clean.status == 0 && clean.line.hasPrefix("ODINSTALOWANO.") && !clean.line.contains("POZOSTAWIONO"), "podsumowanie bez pozostałości: kod 0")
    check((try? w.engine.enable(ID)) == nil, "enable po odinstalowaniu nadal odrzucone")
}
do {
    // Re-review #3: stale prototype cleanup is persistent and leaves an active TailBridge state alone.
    let w = World(); defer { w.cleanup() }
    try! w.engine.enable(ID)
    w.sys.anchors[PFRules.legacyAnchor] = legacyRules.map { $0.replacingOccurrences(of: "utun4", with: "utun7") }
    let oldResolver = w.paths.resolver("old-tail.ts.net")
    w.write(oldResolver, ResolverContent.legacy)
    chmod(w.paths.resolverDir, 0o777)            // resolver step fails on first pass
    _ = try! w.engine.tick()
    check(w.engine.cleanupPending && w.read(oldResolver) == ResolverContent.legacy, "nieudane przeniesienie → zadanie zachowane")
    chmod(w.paths.resolverDir, 0o755)
    let st = try! w.engine.tick()
    check(SafeFiles.info(oldResolver).kind == .absent && w.sys.anchors[PFRules.legacyAnchor] == [] && !w.engine.cleanupPending,
          "ponowienie dokończyło sprzątanie prototypu")
    check(w.sys.anchors[PFRules.anchor]!.count == 4 && w.read(w.resolverPath) == ResolverContent.ours && st.enabled,
          "aktywny stan TailBridge nietknięty")
}

// Re-review 3 (high): a pending prototype-only cleanup must not suspend checks of the own state.
func ownCheckedDuringLegacyCleanup(_ name: String, _ change: (World) -> Void) {
    let w = World(); defer { w.cleanup() }
    try! w.engine.enable(ID)
    w.sys.anchors[PFRules.legacyAnchor] = legacyRules.map { $0.replacingOccurrences(of: "utun4", with: "utun7") }
    w.sys.failFlush = [PFRules.legacyAnchor]
    _ = try! w.engine.tick()
    check(w.engine.cleanupPending && w.sys.anchors[PFRules.anchor]!.count == 4, "\(name): zaległe czyszczenie prototypu, własny stan nietknięty")
    change(w)
    for _ in 0..<2 { _ = try! w.engine.tick() }
    check(w.sys.anchors[PFRules.anchor] == [] && SafeFiles.info(w.resolverPath).kind == .absent,
          "\(name): własne reguły i resolver usunięte mimo zaległego czyszczenia prototypu")
    check(w.engine.cleanupPending, "\(name): czyszczenie prototypu nadal ponawiane")
    w.sys.failFlush = []
    _ = try! w.engine.tick()
    check(!w.engine.cleanupPending && w.sys.anchors[PFRules.legacyAnchor] == [] && w.engine.readDesired() == .absent,
          "\(name): po ustąpieniu błędu wszystko dokończone")
}
ownCheckedDuringLegacyCleanup("zmiana utun") { w in w.sys.addrs = goodAddrs("utun6", index: 22) }
ownCheckedDuringLegacyCleanup("PF wyłączony") { w in w.sys.pfOn = false }
do {
    // Re-review 3 (medium): failed restore of the prototype resolver is reported as incomplete.
    let w = World(); defer { w.cleanup() }
    w.write(w.resolverPath, ResolverContent.legacy)
    w.sys.anchors[PFRules.legacyAnchor] = legacyRules
    w.sys.failFlush = [PFRules.legacyAnchor]
    // Lose the backup exactly when the prototype flush fails, so the rename back cannot succeed.
    w.sys.onPfctl = { a in
        if a == ["-a", PFRules.legacyAnchor, "-F", "rules"] {
            for b in w.backups() where b.hasSuffix("resolver-example-tail.ts.net") { unlink(w.paths.backups + "/" + b) }
        }
    }
    check((try? w.engine.enable(ID)) == nil, "przywracanie: enable odrzucone")
    check(SafeFiles.info(w.resolverPath).kind == .absent, "przywracanie: resolver nieobecny (bezpieczny kierunek)")
    check(w.engine.log.contains { $0.contains("resolver prototypu nie został przywrócony") }, "przywracanie: zgłoszone jako niepełne")
    check(!w.engine.log.contains("Wycofanie zakończone"), "przywracanie: brak fałszywego „Wycofanie zakończone”")
}

do {
    // Re-review 4 (high): a pending own cleanup must not hide a stale prototype.
    let w = World(); defer { w.cleanup() }
    try! w.engine.enable(ID)
    w.sys.anchors[PFRules.legacyAnchor] = legacyRules          // prototype on utun4, still current
    w.sys.failFlush = [PFRules.anchor]
    w.sys.addrs = goodAddrs("utun6", index: 22)                // both now stale
    for _ in 0..<3 { _ = try! w.engine.tick() }
    check(w.sys.anchors[PFRules.legacyAnchor] == [], "nieaktualny prototyp usunięty mimo zaległego własnego czyszczenia")
    check(w.engine.cleanupPending && (try? SafeFiles.read(w.paths.cleanup))?.contains("\"includeLegacy\" : true") == true,
          "zakres zadania rozszerzony o prototyp")
    w.sys.failFlush = []
    _ = try! w.engine.tick()
    check(!w.engine.cleanupPending && w.sys.anchors[PFRules.anchor] == [], "po ustąpieniu błędu wszystko dokończone")
}
do {
    // Re-review 4 (medium): an occupied resolver path makes the rollback incomplete, never "zakończone".
    let w = World(); defer { w.cleanup() }
    w.write(w.resolverPath, ResolverContent.legacy)
    w.sys.anchors[PFRules.legacyAnchor] = legacyRules
    w.sys.failFlush = [PFRules.legacyAnchor]
    w.sys.onPfctl = { a in
        if a == ["-a", PFRules.legacyAnchor, "-F", "rules"] {
            unlink(w.resolverPath); w.write(w.resolverPath, "nameserver 9.9.9.9\n")
        }
    }
    check((try? w.engine.enable(ID)) == nil, "zajęta ścieżka: enable odrzucone")
    check(w.read(w.resolverPath) == "nameserver 9.9.9.9\n", "zajęta ścieżka: obcy plik nie nadpisany")
    check(w.engine.log.contains { $0.contains("jest zajęta") } && !w.engine.log.contains("Wycofanie zakończone"),
          "zajęta ścieżka: zgłoszone jako niepełne")
    check(w.backups().contains { $0.hasSuffix("resolver-example-tail.ts.net") }, "zajęta ścieżka: kopia prototypu zachowana")
}

do {
    // Re-review 5 (low): a failed final unlink keeps the cleanup marker.
    let w = World(); defer { w.cleanup() }
    try! w.engine.enable(ID)
    unlink(w.paths.rulesFile); mkdir(w.paths.rulesFile, 0o755)   // obstacle: unlink(2) cannot remove a directory
    let t = try! w.engine.teardown(reason: "test", includeLegacy: false)
    check(t.failed && w.engine.cleanupPending, "błąd usunięcia pliku reguł zachowuje zadanie")
    rmdir(w.paths.rulesFile)
    _ = try! w.engine.tick()
    check(!w.engine.cleanupPending, "po usunięciu przeszkody zadanie zakończone")
}

section("obserwacja: enabled wymaga wszystkich warunków")
func observedDisabled(_ name: String, _ change: (World) -> Void) {
    let w = World(); defer { w.cleanup() }
    try! w.engine.enable(ID)
    change(w)
    let st = try! w.engine.withLock { w.engine.observeLocked(source: "test") }
    check(!st.enabled && !st.problems.isEmpty, "\(name): enabled=false")
}
observedDisabled("PF wyłączony") { w in w.sys.pfOn = false }
observedDisabled("zła kolejność") { w in w.sys.main = ["anchor \"mullvad\" all", "anchor \"com.apple/*\" all"] }
observedDisabled("brak resolvera") { w in unlink(w.resolverPath) }
observedDisabled("błąd odczytu anchora") { w in w.sys.failRead = [PFRules.anchor] }
do {
    let w = World(); defer { w.cleanup() }
    try! w.engine.enable(ID)
    let st = try! w.engine.withLock { w.engine.observeLocked(source: "test") }
    check(st.enabled && st.problems.isEmpty, "pełny stan → enabled=true")
}

section("monitor")
func monitorTears(_ name: String, _ change: (World) -> Void) {
    let w = World(); defer { w.cleanup() }
    try! w.engine.enable(ID)
    change(w)
    let st = try! w.engine.tick()
    check(w.sys.anchors[PFRules.anchor] == [], "\(name): anchor usunięty")
    check(SafeFiles.info(w.resolverPath).kind == .absent, "\(name): resolver usunięty")
    check(!st.enabled && w.engine.readDesired() == .absent, "\(name): stan wyłączony")
}
monitorTears("Tailscale zatrzymany") { w in w.sys.addrs = goodAddrs().filter { $0.name != "utun4" } }
monitorTears("podmiana utun") { w in
    w.sys.addrs = goodAddrs().filter { $0.name != "utun4" } + [IfAddr(name: "utun4", index: 20, family: AF_INET, address: "10.64.0.9", up: true)]
}
monitorTears("nowy indeks") { w in w.sys.addrs = goodAddrs(index: 40) }
monitorTears("PF wyłączony (reguły wróciłyby po włączeniu)") { w in w.sys.pfOn = false }
monitorTears("zła kolejność anchorów") { w in w.sys.main = ["anchor \"mullvad\" all", "anchor \"com.apple/*\" all"] }
monitorTears("brak resolvera") { w in unlink(w.resolverPath) }
monitorTears("przeniesienie na utun6") { w in w.sys.addrs = goodAddrs("utun6", index: 22) }
monitorTears("przeładowanie PF") { w in w.sys.anchors[PFRules.anchor] = [] }
monitorTears("zmieniony anchor") { w in w.sys.anchors[PFRules.anchor]!.append("pass all") }
do {
    let w = World(); defer { w.cleanup() }
    try! w.engine.enable(ID)
    w.sys.failRead = [PFRules.anchor]
    let st = try! w.engine.tick()
    check(!st.enabled && st.anchor == "error", "błąd odczytu PF: stan nie jest raportowany jako włączony")
    check(SafeFiles.info(w.resolverPath).kind == .absent, "błąd odczytu PF: resolver usunięty")
    check(w.engine.readDesired() != .absent, "błąd odczytu PF: zamiar zachowany (pustka niepotwierdzona)")
    w.sys.failRead = []
    _ = try! w.engine.tick()
    check(w.sys.anchors[PFRules.anchor] == [] && w.engine.readDesired() == .absent, "błąd odczytu PF: dokończone po ustąpieniu")
}
check(!Validate.hostLabel("peer\n") && !Validate.utun("utun4\n"), "końcowy \\n odrzucony we wszystkich wzorcach")
monitorTears("uszkodzony zamiar") { w in w.write(w.paths.desired, "{garbage") }
monitorTears("zamiar ze wstrzyknięciem") { w in
    w.write(w.paths.desired, "{\"iface\":\"utun4;x\",\"index\":20,\"ip4\":\"100.101.102.103\",\"ip6\":\"fd7a:115c:a1e0::1234\",\"domain\":\"example-tail.ts.net\"}")
}
do {
    let w = World(); defer { w.cleanup() }
    w.sys.anchors[PFRules.anchor] = PFRules.expectedPrinted(ID)
    w.write(w.resolverPath, ResolverContent.ours)
    _ = try! w.engine.tick()
    check(w.sys.anchors[PFRules.anchor] == [] && SafeFiles.info(w.resolverPath).kind == .absent, "osierocone elementy bez zamiaru usunięte")
}
do {
    let w = World(); defer { w.cleanup() }
    w.sys.anchors[PFRules.legacyAnchor] = legacyRules
    w.write(w.resolverPath, ResolverContent.legacy)
    _ = try! w.engine.tick()
    check(w.sys.anchors[PFRules.legacyAnchor] == legacyRules, "aktualny prototyp nie jest ruszany automatycznie")
    w.sys.addrs = goodAddrs("utun5", index: 21)
    _ = try! w.engine.tick()
    check(w.sys.anchors[PFRules.legacyAnchor] == [], "nieaktualny prototyp (stary utun) usunięty")
    check(SafeFiles.info(w.resolverPath).kind == .absent && w.backups().contains { $0.hasSuffix("resolver-example-tail.ts.net") },
          "resolver nieaktualnego prototypu przeniesiony do kopii")
}
do {
    let w = World(); defer { w.cleanup() }
    w.sys.anchors[PFRules.legacyAnchor] = ["pass all"]
    w.sys.addrs = []
    _ = try! w.engine.tick()
    check(w.sys.anchors[PFRules.legacyAnchor] == ["pass all"], "nierozpoznany anchor prototypu nietknięty")
}
do {
    let w = World(); defer { w.cleanup() }
    mkdir(w.paths.legacyState, 0o700)
    w.write(w.paths.legacyState + "/marker", "codex-vpn-coexist-v1\n")
    w.write(w.paths.legacyState + "/unexpected", "x")
    check(w.engine.legacyStateKind() == "unknown", "nieznany plik w stanie prototypu")
    try! w.engine.enable(ID)
    check(SafeFiles.info(w.paths.legacyState + "/unexpected").kind == .regular, "nierozpoznany stan prototypu nietknięty")
}

// MARK: - Env file (user side)

section("plik env")
do {
    let w = World(); defer { w.cleanup() }
    let dir = w.root + "/container"
    mkdir(dir, 0o700)
    let env = EnvFile(path: dir + "/tailscaled-env.txt", backupDir: w.root + "/userbackups", owner: getuid())
    check(env.state() == .absent, "brak")
    check(try! env.apply() == true && env.state() == .ours, "utworzony")
    check(SafeFiles.info(env.path).mode == 0o600, "uprawnienia 600")
    check(try! env.apply() == false, "idempotentne")
    let b = try! env.remove()!
    check(env.state() == .absent && w.read(b) == EnvFile.ours, "przeniesiony do kopii")
    w.write(env.path, EnvFile.legacy)
    check(env.state() == .legacy && (try! env.apply()) == false, "prototyp adoptowany bez zmian")
    w.write(env.path, EnvFile.legacy + "TS_DEBUG_X=1\n")
    if case .foreign = env.state() {} else { check(false, "zmieniony = obcy") }
    check((try? env.apply()) == nil && (try? env.remove()) == nil, "obcy: odmowa zapisu i usunięcia")
    check(w.read(env.path) == EnvFile.legacy + "TS_DEBUG_X=1\n", "obcy nietknięty")
    unlink(env.path); symlink("/etc/hosts", env.path)
    check((try? env.apply()) == nil && (try? env.remove()) == nil, "symlink: odmowa")
    check(EnvFile.legacy.utf8.count == 92, "treść prototypu = 92 bajty jak na dysku")
    check(ResolverContent.legacy.utf8.count == 71, "resolver prototypu = 71 bajtów jak na dysku")
}

// MARK: - Parsers

section("parsery")
check(Parsers.mullvadConnected("Connected\n    Relay: se-got-wg-001\n"), "Mullvad Connected")
check(!Parsers.mullvadConnected("Connecting\n") && !Parsers.mullvadConnected("Disconnected\n"), "Mullvad nie połączony")
let tsJSON = """
{"BackendState":"Running","MagicDNSSuffix":"example-tail.ts.net","Self":{"Online":true,"TailscaleIPs":["100.101.102.103","fd7a:115c:a1e0::1234"]}}
"""
check(Parsers.tailscaleSelf(tsJSON) == TailscaleSelf(backendState: "Running", online: true, ip4: ID.ip4, ip6: ID.ip6, domain: ID.domain), "status Tailscale")
check(Parsers.tailscaleSelf("{\"BackendState\":\"Running\",\"MagicDNSSuffix\":\"evil;x.ts.net\"}")?.domain == nil, "zła domena odrzucona")
check(Parsers.tailscaleSelf("not json") == nil, "nie-JSON")
let peersJSON = """
{"BackendState":"Running","Self":{"DNSName":"me.example-tail.ts.net.","TailscaleIPs":["100.101.102.103"]},
 "Peer":{"k1":{"DNSName":"zeta.example-tail.ts.net.","TailscaleIPs":["fd7a:115c:a1e0::9","100.70.0.9"],"Online":false},
         "k2":{"DNSName":"Beta.example-tail.ts.net.","TailscaleIPs":["100.70.0.2"],"Online":true},
         "k3":{"DNSName":"alpha.example-tail.ts.net.","TailscaleIPs":["100.70.0.1"],"Online":true},
         "k4":{"DNSName":"bad;name.example-tail.ts.net.","TailscaleIPs":["100.70.0.4"],"Online":false},
         "k5":{"DNSName":"noip.example-tail.ts.net.","TailscaleIPs":["8.8.8.8"],"Online":true},
         "k6":{"DNSName":"magic.example-tail.ts.net.","TailscaleIPs":["100.100.100.100"],"Online":true}}}
"""
check(Parsers.peers(peersJSON) == [Peer(name: "alpha", ip4: "100.70.0.1", online: true),
                                   Peer(name: "beta", ip4: "100.70.0.2", online: true),
                                   Peer(name: "", ip4: "100.70.0.4", online: false),
                                   Peer(name: "zeta", ip4: "100.70.0.9", online: false)], "lista peerów: online najpierw, bez self, bez złych IP i nazw")
check(Parsers.peers(tsJSON).isEmpty && Parsers.peers("not json").isEmpty, "lista peerów pusta bez Peer / nie-JSON")
section("publiczny IPv4/IPv6 (regresja: zmapowany adres zaliczał IPv6)")
do {
    // Rodzina adresu: ::ffff:a.b.c.d to ruch IPv4.
    check(Parsers.addressFamily("203.0.113.7") == .ipv4, "IPv4")
    check(Parsers.addressFamily("::ffff:45.83.223.233") == .ipv4Mapped, "zmapowany IPv4 (zapis kropkowy)")
    check(Parsers.addressFamily("::FFFF:2d53:dfe9") == .ipv4Mapped, "zmapowany IPv4 (zapis szesnastkowy, wielkie litery)")
    check(Parsers.addressFamily("2a03:1b20:bef1::1") == .ipv6 && Parsers.addressFamily("2001:db8::7") == .ipv6, "prawdziwy IPv6")
    // IPv4-compatible (::a.b.c.d) i NAT64 (64:ff9b::/96) są składniowo IPv6; o wyniku rozstrzyga adres widziany przez serwer.
    check(Parsers.addressFamily("::1.2.3.4") == .ipv6 && Parsers.addressFamily("64:ff9b::2d53:dfe9") == .ipv6, "IPv4-compatible i NAT64 jako IPv6")
    for bad in ["", "1.2.3", "01.2.3.4", "256.1.1.1", "fe80::1%en0", "not-an-ip", "1.2.3.4 ", "::ffff:1.2.3.4\n"] {
        check(Parsers.addressFamily(bad) == nil, "odrzucony adres: \(bad.debugDescription)")
    }

    // Argumenty curl: -q pierwszy, proxy wyłączone, osobne endpointy, adres połączenia w wierszu diagnostycznym.
    for fam in ["IPv4", "IPv6"] {
        let a = PublicIPCheck.curlArgs(fam)
        check(a.first == "-q", "\(fam): -q jako pierwszy argument (bez ~/.curlrc)")
        check(a.firstIndex(of: "--noproxy").map { a[$0 + 1] == "*" } == true, "\(fam): --noproxy *")
        check(a.contains(fam == "IPv4" ? "-4" : "-6") && !a.contains(fam == "IPv4" ? "-6" : "-4"), "\(fam): tylko jedna rodzina")
        check(a.last == (fam == "IPv4" ? "https://ipv4.am.i.mullvad.net/json" : "https://ipv6.am.i.mullvad.net/json"), "\(fam): osobny endpoint")
        check(!a.contains("https://am.i.mullvad.net/connected"), "\(fam): bez wspólnego hosta bez AAAA")
        check(a.firstIndex(of: "--proto").map { a[$0 + 1] == "=https" } == true, "\(fam): tylko https")
        // Dokładnie: curl zamienia literalne \n na nowy wiersz; bez niego lub bez znacznika parser nie znajdzie wiersza.
        check(a.firstIndex(of: "-w").map { a[$0 + 1] == "\\n" + PublicIPCheck.marker + "%{http_code} %{remote_ip}" } == true,
              "\(fam): pełny wiersz diagnostyczny curl")
    }

    func run(_ json: String, _ tail: String, status: Int32 = 0, _ fam: String) -> CheckResult {
        Parsers.mullvadCheck(curl: ProcResult(status: status, out: json + "\n" + PublicIPCheck.marker + tail, err: ""), family: fam)
    }
    let v4ok = #"{"ip":"203.0.113.7","country":"Sweden","mullvad_exit_ip":true,"mullvad_exit_ip_hostname":"se-got-wg-001"}"#
    let v6ok = #"{"ip":"2001:db8::7","country":"Sweden","mullvad_exit_ip":true,"mullvad_exit_ip_hostname":"se-got-wg-001"}"#

    let p4 = run(v4ok, "200 45.83.223.233", "IPv4")
    check(p4.verdict == .pass && p4.detail.contains("se-got-wg-001") && !p4.detail.contains("203.0.113.7"), "IPv4 przez Mullvad, bez IP: \(p4.detail)")
    let p6 = run(v6ok, "200 2a03:1b20:bef1::1", "IPv6")
    check(p6.verdict == .pass && !p6.detail.contains("2001:db8"), "prawdziwy IPv6 przez Mullvad: \(p6)")

    // Przypadek historyczny: curl -6 połączył się przez ::ffff:IPv4, serwer widział IPv4 Mullvada.
    let hist = run(#"{"ip":"203.0.113.7","mullvad_exit_ip":true}"#, "200 ::ffff:45.83.223.233", "IPv6")
    check(hist.verdict == .inconclusive && hist.reason == .family, "IPv6 przez zmapowany IPv4: nierozstrzygnięty, nie Passed")
    check(run(v6ok, "200 ::ffff:45.83.223.233", "IPv6").verdict == .inconclusive, "IPv6: połączenie przez ::ffff:IPv4 nie zalicza, nawet gdy serwer podaje IPv6")
    check(run(#"{"ip":"::ffff:203.0.113.7","mullvad_exit_ip":true}"#, "200 2a03:1b20:bef1::1", "IPv6").reason == .family, "IPv6: serwer widział ::ffff:IPv4")
    check(run(#"{"ip":"203.0.113.7","mullvad_exit_ip":true}"#, "200 2a03:1b20:bef1::1", "IPv6").reason == .family, "IPv6: serwer widział IPv4")
    let nat64 = run(#"{"ip":"203.0.113.7","mullvad_exit_ip":true}"#, "200 64:ff9b::2d53:dfe9", "IPv6")
    check(nat64.verdict == .inconclusive && nat64.reason == .family, "IPv6 przez NAT64 (serwer widział IPv4): nierozstrzygnięty")
    check(run(v6ok, "200 45.83.223.233", "IPv4").reason == .family, "IPv4: serwer widział IPv6")
    check(run(#"{"ip":"::ffff:203.0.113.7","mullvad_exit_ip":true}"#, "200 45.83.223.233", "IPv4").verdict == .pass, "IPv4: serwer zapisał IPv4 jako zmapowany")
    // Niezgodna rodzina rozstrzyga przed mullvad_exit_ip: inna rodzina nie jest dowodem dla testowanej.
    check(run(#"{"ip":"203.0.113.7","mullvad_exit_ip":false}"#, "200 ::ffff:45.83.223.233", "IPv6").verdict == .inconclusive, "niezgodna rodzina i nie-Mullvad: nierozstrzygnięty")

    check(run(#"{"ip":"2001:db8::7","mullvad_exit_ip":false}"#, "200 2a03:1b20:bef1::1", "IPv6").verdict == .leak, "IPv6 poza Mullvad")
    check(run(#"{"ip":"203.0.113.7","mullvad_exit_ip":false}"#, "200 45.83.223.233", "IPv4").verdict == .leak, "IPv4 poza Mullvad")

    // Błędne lub niepełne odpowiedzi: nierozstrzygnięte, nigdy Passed ani wyciek.
    let bad: [(String, String, String)] = [
        ("<html>", "200 45.83.223.233", "HTML"),
        ("You are connected to Mullvad (server se-got-wg-001). Your IP address is 203.0.113.7", "200 45.83.223.233", "stary format tekstowy"),
        (#"{"mullvad_exit_ip":true}"#, "200 45.83.223.233", "brak ip"),
        (#"{"ip":"not-an-ip","mullvad_exit_ip":true}"#, "200 45.83.223.233", "ip nie jest adresem"),
        (#"{"ip":"203.0.113.7"}"#, "200 45.83.223.233", "brak mullvad_exit_ip"),
        (#"{"ip":"203.0.113.7","mullvad_exit_ip":1}"#, "200 45.83.223.233", "mullvad_exit_ip jako liczba"),
        (#"{"ip":"203.0.113.7","mullvad_exit_ip":"true"}"#, "200 45.83.223.233", "mullvad_exit_ip jako tekst"),
        (#"["203.0.113.7"]"#, "200 45.83.223.233", "tablica zamiast obiektu"),
        (v4ok, "404 45.83.223.233", "HTTP 404"),
        (v4ok, "200 ", "brak adresu połączenia"),
        (v4ok, "200", "wiersz bez adresu"),
        (v4ok, "200 not-an-ip", "zły adres połączenia"),
    ]
    for (body, tail, what) in bad {
        let r = run(body, tail, "IPv4")
        check(r.verdict == .inconclusive && r.reason == .response, "błędna odpowiedź (\(what)): \(r.verdict)")
    }
    check(Parsers.mullvadCheck(curl: ProcResult(status: 0, out: v4ok, err: ""), family: "IPv4").verdict == .inconclusive, "bez wiersza diagnostycznego")
    check(Parsers.mullvadCheck(curl: ProcResult(status: 22, out: "", err: ""), family: "IPv4").verdict == .inconclusive, "nieznany błąd curl")
    // Serwer nie może podrobić wiersza curl: liczy się tylko ostatni wiersz.
    let spoof = run(v6ok + "\n" + PublicIPCheck.marker + "200 2a03:1b20:bef1::1", "200 ::ffff:45.83.223.233", "IPv6")
    check(spoof.verdict == .inconclusive, "podrobiony wiersz w treści nie zalicza IPv6")
    check(!run(#"{"ip":"203.0.113.7","mullvad_exit_ip":true,"mullvad_exit_ip_hostname":"evil (x)\n"}"#, "200 45.83.223.233", "IPv4").detail.contains("evil"),
          "niebezpieczna nazwa serwera pominięta")

    // Brak łączności: niedostępne — ani wyciek, ani skuteczna ochrona.
    for (status, timedOut) in [(Int32(7), false), (Int32(6), false), (Int32(28), false), (Int32(35), false), (Int32(45), false), (Int32(0), true)] {
        let r = Parsers.mullvadCheck(curl: ProcResult(status: status, out: "\n" + PublicIPCheck.marker + "000 ", err: "", timedOut: timedOut), family: "IPv6")
        check(r.verdict == .unavailable && r.detail.contains("nie jest dowód"), "brak łączności (curl \(status), timeout \(timedOut)) → niedostępne")
    }
}
check(Parsers.tailscalePath("pong from peer (100.77.0.1) via DERP(xyz) in 41ms\n") == .derp("xyz"), "DERP")
check(Parsers.tailscalePath("pong from peer (100.77.0.1) via 203.0.113.5:41641 in 4ms\n") == .direct, "direct")
check(Parsers.tailscalePath("timeout waiting for ping\n") == .none, "brak odpowiedzi")
check(Parsers.tsmpPong("pong from peer (100.77.0.1, 0) via TSMP in 50ms\n"), "TSMP")

// MARK: - SafeFiles

section("pliki")
do {
    let w = World(); defer { w.cleanup() }
    let p = w.root + "/f"
    try! SafeFiles.createExclusive(p, "a", mode: 0o644)
    check((try? SafeFiles.createExclusive(p, "b", mode: 0o644)) == nil, "O_EXCL")
    symlink(p, w.root + "/l")
    check((try? SafeFiles.read(w.root + "/l")) == nil, "odczyt nie podąża za symlinkiem")
    check((try? SafeFiles.replaceAtomic(w.root + "/l", "x", mode: 0o644)) == nil, "zamiana symlinku odrzucona")
    check(w.read(p) == "a", "cel symlinku nietknięty")
    let big = String(repeating: "x", count: 70_000)
    try! big.write(toFile: w.root + "/big", atomically: false, encoding: .utf8)
    check((try? SafeFiles.read(w.root + "/big")) == nil, "limit rozmiaru")
}

section("ACL i instalator")
do {
    let w = World(); defer { w.cleanup() }
    let d = w.root + "/acl"
    mkdir(d, 0o755)
    check(SafeFiles.untrustedDirReason(d, owner: getuid(), base: w.root) == nil, "katalog bez ACL zaufany")
    let r = Proc.run("/bin/chmod", ["+a", "everyone allow add_file,delete_child", d])
    check(r.ok, "nadanie ACL w teście")
    check(SafeFiles.untrustedDirReason(d, owner: getuid(), base: w.root) != nil, "ACL allow → niezaufany")
    func sh(_ dir: String) -> Bool { Proc.run("/bin/sh", ["-c", Privileged.dirCheckFunction + "; chk \"$1\"", "sh", dir]).ok }
    check(sh("/"), "chk / (root, 755, bez ACL)")
    check(!sh(w.root), "chk: katalog nie-roota odrzucony")
    check(!sh(d), "chk: ACL odrzucony")
    symlink("/", w.root + "/link")
    check(!sh(w.root + "/link"), "chk: symlink odrzucony")
    func shf(_ f: String) -> Bool { Proc.run("/bin/sh", ["-c", Privileged.dirCheckFunction + "; chkf \"$1\"", "sh", f]).ok }
    check(shf("/bin/ls"), "chkf: plik root 755 zaufany")
    w.write(w.root + "/userfile", "x")
    check(!shf(w.root + "/userfile"), "chkf: plik użytkownika odrzucony")
    symlink("/bin/ls", w.root + "/flink")
    check(!shf(w.root + "/flink"), "chkf: symlink odrzucony")
    let cmd = Privileged.installCommand(source: "/x/h", sha256: String(repeating: "b", count: 64))!
    let order = ["chk /;", "chk /Library;", "chk /Library/PrivilegedHelperTools;", "then chkf '/Library/PrivilegedHelperTools/com.tailbridge.helper'",
                 "mktemp", "shasum", "install-daemon"]
    let pos = order.map { cmd.range(of: $0)?.lowerBound }
    check(pos.allSatisfy { $0 != nil } && zip(pos, pos.dropFirst()).allSatisfy { $0! < $1! }, "instalator: kontrole przed operacjami")
    check(cmd.contains(".com.tailbridge.helper.previous"), "instalator: poprzednia wersja zachowana do przywrócenia")
    check(!cmd.contains("|| true"), "instalator: błędy przywracania nie są maskowane")
    check(Proc.run("/bin/sh", ["-n", "-c", cmd]).ok, "instalator: poprawna składnia sh")
    check(Privileged.appleScript(command: "x", prompt: "p").contains("TAILBRIDGE_EXIT=$?"), "jawny kod wyjścia")
    check(Privileged.exitStatus("a\nTAILBRIDGE_EXIT=2\n") == 2 && Privileged.exitStatus("a\n") == nil, "parser kodu wyjścia")
}


// MARK: - Process runner

section("Proc: deskryptory i wyniki uruchomienia")
func openFDCount() -> Int {
    var rl = rlimit(); getrlimit(RLIMIT_NOFILE, &rl)
    let top = Int32(min(rl.rlim_cur, 65536))
    return (0..<top).filter { fcntl($0, F_GETFD) != -1 }.count
}
do {
    _ = Proc.run("/bin/echo", ["warm-up"])          // Foundation opens its own long-lived descriptors once
    let base = openFDCount()
    var allCorrect = true
    for _ in 0..<300 { let r = Proc.run("/bin/echo", ["Status: Enabled"]); allCorrect = allCorrect && r.ok && r.out == "Status: Enabled\n" }
    check(allCorrect, "300 uruchomień: poprawne wyjście")
    check(openFDCount() <= base + 2, "300 uruchomień nie zostawia deskryptorów (\(base) → \(openFDCount()))")

    let both = Proc.run("/bin/sh", ["-c", "echo out; echo err >&2; exit 3"])
    check(both.status == 3 && both.out == "out\n" && both.err == "err\n", "stdout, stderr i kod wyjścia rozdzielone")
    let piped = Proc.run("/bin/cat", [], stdin: Data("abc".utf8))
    check(piped.ok && piped.out == "abc", "stdin przekazany")
    for _ in 0..<50 { _ = Proc.run("/bin/cat", [], stdin: Data("x".utf8)) }
    check(openFDCount() <= base + 2, "stdin nie zostawia deskryptorów")
    let big = Proc.run("/bin/sh", ["-c", "head -c 200000 /dev/zero"])
    check(big.ok && big.out.utf8.count == 200000, "duże wyjście odczytane w całości")

    let slow = Proc.run("/bin/sleep", ["5"], timeout: 0.3)
    check(slow.timedOut && !slow.ok, "limit czasu przerywa proces")
    check(openFDCount() <= base + 2, "przekroczenie czasu nie zostawia deskryptorów")

    // A grandchild keeps stdout open after the child exits: run returns, and the drain closes its end at EOF.
    let t0 = Date()
    _ = Proc.run("/bin/sh", ["-c", "/bin/sleep 1 & echo started"], timeout: 5)
    check(Date().timeIntervalSince(t0) < 4, "wnuk trzymający potok nie blokuje bez końca")
    usleep(1_800_000)
    check(openFDCount() <= base + 2, "po zakończeniu wnuka deskryptory zamknięte")

    // Grandchild outlives the 2 s grace period: the output may be incomplete, so it is not a success.
    let held = Proc.run("/bin/sh", ["-c", "/bin/echo present; /bin/sleep 4 &"], timeout: 10)
    check(!held.ok && held.out == "present\n" && held.err.contains("output incomplete"),
          "niepełne wyjście nie jest sukcesem i zachowuje to, co doszło: ok=\(held.ok) out=\(held.out.debugDescription)")
    usleep(2_500_000)
    check(openFDCount() <= base + 2, "po zakończeniu długiego wnuka deskryptory zamknięte")

    // stdin to a child that exits at once: no SIGPIPE for the caller (the test process would die).
    let early = Proc.run("/bin/sh", ["-c", "exit 0"], stdin: Data(count: 1 << 20))
    check(early.ok, "stdin do zakończonego procesu: brak SIGPIPE")
    // stdin to a child that never reads: the timeout still applies.
    let t1 = Date()
    let stuck = Proc.run("/bin/sleep", ["5"], timeout: 0.3, stdin: Data(count: 1 << 20))
    check(stuck.timedOut && Date().timeIntervalSince(t1) < 3, "limit czasu działa, gdy proces nie czyta stdin")
    // A leftover process holds stdin open without reading: the writer still ends before run returns.
    let before = openFDCount(), t2 = Date()
    let orphan = Proc.run("/bin/sh", ["-c", "/bin/sleep 3 <&0 >/dev/null 2>/dev/null & exit 0"], stdin: Data(count: 1 << 20))
    check(orphan.ok && Date().timeIntervalSince(t2) < 1, "stdin trzymany przez pozostały proces: run kończy się od razu")
    check(openFDCount() <= before, "stdin trzymany przez pozostały proces: zapisujący nie zostawia deskryptora (\(before) → \(openFDCount()))")
    usleep(300_000)
    check(openFDCount() <= base + 2, "stdin: deskryptory zamknięte po przekroczeniu czasu")
}

section("Proc: limit wyjścia 1 MiB")
do {
    let limit = Proc.maxOutput
    check(limit == 1 << 20, "limit wynosi 1 MiB")
    func head(_ n: Int, toErr: Bool = false) -> ProcResult {
        Proc.run("/bin/sh", ["-c", "/usr/bin/head -c \(n) /dev/zero" + (toErr ? " >&2" : "")])
    }
    let below = head(limit - 1)
    check(below.ok && !below.truncated && below.out.utf8.count == limit - 1 && below.err.isEmpty, "stdout poniżej limitu: pełne, sukces")
    let exact = head(limit)
    check(exact.ok && !exact.truncated && exact.out.utf8.count == limit && exact.err.isEmpty, "stdout dokładnie na limicie: pełne, sukces")
    let above = head(limit + 1)
    check(!above.ok && above.truncated && above.status == 0 && !above.timedOut && above.out.utf8.count == limit,
          "stdout powyżej limitu: obcięte do limitu, nie sukces (ok=\(above.ok) bajty=\(above.out.utf8.count))")
    check(above.err.contains("output truncated: stdout exceeded the \(limit)-byte limit"), "stdout powyżej limitu: komunikat o obcięciu: \(above.err.debugDescription)")
    let huge = head(8 * limit)
    check(huge.truncated && !huge.timedOut && huge.out.utf8.count == limit, "dużo powyżej limitu: proces doczytany do końca, bez limitu czasu")
    let errExact = head(limit, toErr: true)
    check(errExact.ok && !errExact.truncated && errExact.err.utf8.count == limit, "stderr dokładnie na limicie: pełne, sukces")
    let errAbove = head(limit + 1, toErr: true)
    check(!errAbove.ok && errAbove.truncated && errAbove.out.isEmpty && errAbove.err.hasPrefix(String(repeating: "\0", count: 16))
          && errAbove.err.hasSuffix("output truncated: stderr exceeded the \(limit)-byte limit; the rest was discarded"),
          "stderr powyżej limitu: obcięte, nie sukces, komunikat o obcięciu")
    check(!ProcResult(status: 0, out: "x", err: "", truncated: true).ok, "obcięty wynik nigdy nie jest sukcesem")
}

section("Proc: brak wolnych deskryptorów to błąd, nie pusty sukces")
do {
    var old = rlimit()
    check(getrlimit(RLIMIT_NOFILE, &old) == 0, "odczyt limitu deskryptorów")
    var low = old; low.rlim_cur = rlim_t(openFDCount() + 40)
    check(setrlimit(RLIMIT_NOFILE, &low) == 0, "obniżenie limitu na czas testu")
    var fillers: [Int32] = []
    while true { let fd = open("/dev/null", O_RDONLY); if fd < 0 { break }; fillers.append(fd) }
    check(!fillers.isEmpty, "tablica deskryptorów zapełniona (\(fillers.count))")
    // With 0…6 free slots every result is either the real output or an error, never exit 0 with no output.
    var silentEmpty = 0, errors = 0, correct = 0
    for free in 0...6 {
        for _ in 0..<free { if let fd = fillers.popLast() { close(fd) } }
        let r = Proc.run("/bin/echo", ["Status: Enabled"])
        if r.ok && r.out.isEmpty { silentEmpty += 1 } else if r.ok && r.out == "Status: Enabled\n" { correct += 1 } else if !r.ok { errors += 1 }
        while true { let fd = open("/dev/null", O_RDONLY); if fd < 0 { break }; fillers.append(fd) }
    }
    check(silentEmpty == 0, "nigdy kod 0 z pustym wyjściem (błędy: \(errors), poprawne: \(correct))")
    check(errors > 0, "przy pełnej tablicy zgłaszany błąd")
    let starved = Proc.run("/bin/echo", ["x"])
    check(!starved.ok && starved.err.contains("cannot run"), "komunikat błędu: \(starved.err)")
    fillers.forEach { close($0) }
    check(setrlimit(RLIMIT_NOFILE, &old) == 0, "przywrócenie limitu")
    let after = Proc.run("/bin/echo", ["ok"])
    check(after.ok && after.out == "ok\n", "po zwolnieniu deskryptorów działa ponownie")
}

section("Proc: test długotrwały (TAILBRIDGE_SOAK=liczba, 0 pomija)")
do {
    let runs = Int(ProcessInfo.processInfo.environment["TAILBRIDGE_SOAK"] ?? "") ?? 10_000
    if runs > 0 {
        let batch = 500
        let base = openFDCount()
        var peak = base
        let lock = NSLock()
        var wrong: [String] = []
        var kinds = [Int](repeating: 0, count: 6)
        let t0 = Date()
        var done = 0
        // A stall must fail the suite, not hang build.sh.
        let progress = NSLock(); var finished = 0
        Thread.detachNewThread {
            var last = 0
            while true {
                sleep(60)
                progress.lock(); let now = finished; progress.unlock()
                if now >= runs { return }
                if now == last { print("FAIL: test długotrwały stoi na \(now)/\(runs) uruchomieniach"); exit(1) }
                last = now
            }
        }
        while done < runs {
            let start = done, n = min(batch, runs - done)
            // Several runs at once, as the app and the helper do from different threads.
            DispatchQueue.concurrentPerform(iterations: n) { k in
                let i = start + k
                let kind = i % 1000 == 999 ? 5 : i % 5
                let r: ProcResult, good: Bool
                switch kind {
                case 0:
                    r = Proc.run("/bin/echo", ["run-\(i)"])
                    good = r.ok && r.out == "run-\(i)\n" && r.err.isEmpty
                case 1:
                    r = Proc.run("/bin/sh", ["-c", "printf %s \"$1\"; printf e%s \"$1\" >&2; exit $2", "sh", "\(i)", "\(i % 7)"])
                    good = r.status == Int32(i % 7) && !r.timedOut && r.out == "\(i)" && r.err == "e\(i)"
                case 2:
                    let input = "in-\(i)-" + String(repeating: "x", count: i % 3000)
                    r = Proc.run("/bin/cat", [], stdin: Data(input.utf8))
                    good = r.ok && r.out == input && r.err.isEmpty
                case 3:
                    let size = 70_000 + i % 1000             // more than one pipe buffer
                    r = Proc.run("/usr/bin/head", ["-c", "\(size)", "/dev/zero"])
                    good = r.ok && r.out.utf8.count == size && r.err.isEmpty
                case 4:
                    r = Proc.run("/usr/bin/false", [])
                    good = r.status == 1 && !r.timedOut && !r.ok && r.out.isEmpty && r.err.isEmpty
                default:
                    r = Proc.run("/bin/sleep", ["5"], timeout: 0.05)
                    good = r.timedOut && !r.ok
                }
                progress.lock(); finished += 1; progress.unlock()
                lock.lock()
                kinds[kind] += 1
                if !good && wrong.count < 10 {
                    wrong.append("#\(i) rodzaj \(kind): status=\(r.status) timedOut=\(r.timedOut) out=\(r.out.prefix(40).debugDescription) err=\(r.err.prefix(80).debugDescription)")
                }
                lock.unlock()
            }
            done += n
            peak = max(peak, openFDCount())
        }
        let secs = Date().timeIntervalSince(t0)
        print("  \(runs) uruchomień w \(String(format: "%.1f", secs)) s, rodzaje \(kinds), deskryptory \(base) → szczyt \(peak)")
        check(wrong.isEmpty, "test długotrwały: wszystkie wyniki poprawne: \(wrong)")
        check(kinds.reduce(0, +) == runs, "test długotrwały: wykonano wszystkie uruchomienia")
        check(peak <= base + 2, "test długotrwały: liczba deskryptorów nie rośnie (\(base) → szczyt \(peak))")
    }
}

section("PF: włączony, wyłączony, nieczytelny")
check(PFRules.pfState("No ALTQ support in kernel\nALTQ related functions disabled\nStatus: Enabled for 0 days 17:19:20           Debug: Urgent\n") == .enabled, "rzeczywisty wydruk: włączony")
check(PFRules.pfState("Status: Disabled for 0 days 00:00:12          Debug: Urgent\n") == .disabled, "wyłączony")
check(PFRules.pfState("   Status: Enabled for 1 days") == .enabled, "wcięcie nie przeszkadza")
for bad in ["", "\n", "No ALTQ support in kernel\nALTQ related functions disabled\n", "pfctl: /dev/pf: Permission denied", "Status:"] {
    check(PFRules.pfState(bad) == .unreadable, "nieczytelny: \(bad.debugDescription)")
}
let goodMain = ["anchor \"com.apple/*\" all", "anchor \"mullvad\" all"]
check(PFRules.mainOrder(ProcResult(status: 0, out: goodMain.joined(separator: "\n"), err: "")) == true, "kolejność z wydruku")
check(PFRules.mainOrder(ProcResult(status: 0, out: goodMain.reversed().joined(separator: "\n"), err: "")) == false, "zła kolejność z wydruku")
check(PFRules.mainOrder(ProcResult(status: 0, out: "", err: "")) == nil, "pusty wydruk reguł: nieczytelny")
check(PFRules.mainOrder(ProcResult(status: 1, out: "", err: "x")) == nil, "błąd pfctl: nieczytelny")

do {
    let w = World(); defer { w.cleanup() }
    w.sys.infoOut = ""
    var message = ""
    do { try w.engine.enable(ID) } catch { message = "\(error)" }
    check(message.contains("nie można odczytać stanu PF"), "enable przy nieczytelnym PF: \(message)")
    check(w.sys.anchors[PFRules.anchor] == nil && w.engine.readDesired() == .absent, "enable przy nieczytelnym PF: nic nie zmieniono")
}
do {
    let w = World(); defer { w.cleanup() }
    w.sys.main = []
    var message = ""
    do { try w.engine.enable(ID) } catch { message = "\(error)" }
    check(message.contains("nie można odczytać reguł głównych"), "enable przy pustych regułach głównych: \(message)")
}
do {
    let w = World(); defer { w.cleanup() }
    w.sys.pfOn = false
    var message = ""
    do { try w.engine.enable(ID) } catch { message = "\(error)" }
    check(message.contains("PF nie jest włączony"), "enable przy wyłączonym PF: \(message)")
}
do {
    // The incident: every pfctl call exits 0 with nothing printed. That is unknown state, not "PF off".
    let w = World(); defer { w.cleanup() }
    w.sys.allEmpty = true
    let st = try! w.engine.withLock { w.engine.observeLocked(source: "test") }
    check(st.pfEnabled == nil && st.appleBeforeMullvad == nil, "puste wyniki: PF i kolejność nieznane (pf=\(String(describing: st.pfEnabled)), order=\(String(describing: st.appleBeforeMullvad)))")
    check(!st.enabled, "puste wyniki: nie raportuje włączenia")
}
do {
    let w = World(); defer { w.cleanup() }
    try! w.engine.enable(ID)
    w.sys.infoOut = ""
    let st = try! w.engine.withLock { w.engine.observeLocked(source: "test") }
    check(st.pfEnabled == nil && st.problems.contains("nie można odczytać stanu PF") && !st.problems.contains("PF wyłączony"),
          "obserwacja: nieczytelny PF zgłaszany jako błąd odczytu: \(st.problems)")
    w.sys.infoOut = nil; w.sys.pfOn = false
    let off = try! w.engine.withLock { w.engine.observeLocked(source: "test") }
    check(off.pfEnabled == false && off.problems.contains("PF wyłączony"), "obserwacja: wyłączony PF nadal rozpoznany")
}
monitorTears("PF nieczytelny (bez potwierdzenia zdejmuje obejście)") { w in w.sys.infoOut = "" }

print("\nWynik: \(passes) OK, \(failures) BŁĘDÓW")
exit(failures == 0 ? 0 : 1)
