import Foundation

/// Everything the privileged engine touches outside its own files. Faked in tests.
protocol SystemOps {
    func pfctl(_ args: [String]) -> ProcResult
    func interfaces() -> [IfAddr]
    /// Flushes resolver caches; returns warnings (never fatal).
    func flushDNS() -> [String]
}

struct Paths {
    var base: String          // /Library/Application Support/TailBridge
    var resolverDir: String   // /private/etc/resolver
    var legacyState: String   // /private/var/run/codex-vpn-coexist
    var owner: uid_t          // 0 in production
    var trustBase: String     // "/" in production
    var desired: String { base + "/enabled.json" }
    /// Present while a teardown is owed; the watchdog retries until it completes.
    var cleanup: String { base + "/cleanup-required.json" }
    /// Written under the lock by `uninstall`; makes every later `enable` refuse until reinstall.
    var uninstalling: String { base + "/uninstalled" }
    var status: String { base + "/status.json" }
    var rulesFile: String { base + "/anchor.rules" }
    var backups: String { base + "/backups" }
    var lock: String { base + "/.lock" }
    func resolver(_ domain: String) -> String { resolverDir + "/" + domain }
}

enum ResolverContent {
    static let ours = "# TailBridge managed resolver v1 (usuwany przez TailBridge \"Wyłącz\")\nnameserver 100.100.100.100\n"
    static let legacy = "# Local codex Mullvad/Tailscale resolver v1\nnameserver 100.100.100.100\n"
}

enum ResolverState: Equatable {
    case absent, ours, legacy, foreign(String)
    var label: String {
        switch self {
        case .absent: return "absent"
        case .ours: return "ours"
        case .legacy: return "legacy"
        case .foreign: return "foreign"
        }
    }
    static func of(_ path: String) -> ResolverState {
        switch SafeFiles.info(path).kind {
        case .absent: return .absent
        case .regular:
            guard let s = try? SafeFiles.read(path) else { return .foreign("nieczytelny") }
            if s == ResolverContent.ours { return .ours }
            if s == ResolverContent.legacy { return .legacy }
            return .foreign("nierozpoznana treść")
        default: return .foreign("nie jest zwykłym plikiem")
        }
    }
}

struct HelperStatus: Codable {
    var version = 1
    var updatedAt: Date
    var source: String
    var enabled: Bool           // true only if every required observation holds
    var identity: Identity?
    var anchor: String          // empty | exact | mismatch | error
    var pfEnabled: Bool?
    var appleBeforeMullvad: Bool?
    var resolver: String        // ours | absent | legacy | foreign | n/a
    var legacyAnchor: String    // empty | recognized | unknown | error
    var legacyState: String     // absent | recognized | unknown
    var cleanupPending: Bool
    var lastEvent: String
    var problems: [String]
}

enum Desired: Equatable { case absent, corrupt, valid(Identity) }

/// Result of a teardown. `failed`: something owned may remain, retry needed.
/// `leftovers`: unrecognised items deliberately left untouched (not retried).
struct Teardown {
    var failed = false
    var leftovers: [String] = []
    var complete: Bool { !failed && leftovers.isEmpty }
}

/// `ownToo == false`: only prototype leftovers (stale legacy anchor/resolver) are owed.
private struct CleanupMarker: Codable {
    var includeLegacy: Bool
    var ownToo: Bool?
    var reason: String
    var own: Bool { ownToo ?? true }
}

final class Engine {
    let sys: SystemOps
    let paths: Paths
    private(set) var log: [String] = []
    private var lastEvent = ""

    init(sys: SystemOps, paths: Paths) { self.sys = sys; self.paths = paths }

    func note(_ s: String) { log.append(s) }

    func drainLog() -> [String] { defer { log = [] }; return log }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private func json<T: Encodable>(_ v: T) throws -> String { String(decoding: try Engine.encoder.encode(v), as: UTF8.self) + "\n" }

    // MARK: - plumbing

    func prepare() throws {
        if let why = SafeFiles.untrustedDirReason(paths.base, owner: paths.owner, base: paths.trustBase) {
            if SafeFiles.info(paths.base).kind == .absent {
                let parent = (paths.base as NSString).deletingLastPathComponent
                if let w = SafeFiles.untrustedDirReason(parent, owner: paths.owner, base: paths.trustBase) { throw FSError(w) }
                try SafeFiles.ensureDir(paths.base, mode: 0o755)
            } else { throw FSError(why) }
        }
        try SafeFiles.ensureDir(paths.backups, mode: 0o700)
        if let why = SafeFiles.untrustedDirReason(paths.backups, owner: paths.owner, base: paths.trustBase) { throw FSError(why) }
    }

    func withLock<T>(_ body: () throws -> T) throws -> T {
        try prepare()
        let fd = open(paths.lock, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw FSError("nie można otworzyć blokady") }
        defer { flock(fd, LOCK_UN); close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw FSError("nie można uzyskać blokady") }
        return try body()
    }

    /// Printed rules of an anchor, or nil when pfctl failed.
    func readAnchor(_ name: String) -> [String]? {
        let r = sys.pfctl(["-a", name, "-sr"])
        return r.ok ? r.lines : nil
    }

    func readDesired() -> Desired {
        guard SafeFiles.info(paths.desired).kind != .absent else { return .absent }
        guard let s = try? SafeFiles.read(paths.desired),
              let id = try? Engine.decoder.decode(Identity.self, from: Data(s.utf8)),
              id.fieldsValid else { return .corrupt }
        return .valid(id)
    }

    /// nil: no cleanup owed. A corrupt marker is treated as a full cleanup request.
    private func readCleanup() -> CleanupMarker? {
        guard SafeFiles.info(paths.cleanup).kind != .absent else { return nil }
        guard let s = try? SafeFiles.read(paths.cleanup),
              let m = try? Engine.decoder.decode(CleanupMarker.self, from: Data(s.utf8)) else {
            return CleanupMarker(includeLegacy: true, ownToo: true, reason: "nieczytelny znacznik czyszczenia")
        }
        return m
    }

    var cleanupPending: Bool { SafeFiles.info(paths.cleanup).kind != .absent }

    func legacyStateKind() -> String {
        let i = SafeFiles.info(paths.legacyState)
        if i.kind == .absent { return "absent" }
        guard i.kind == .directory, i.uid == paths.owner, i.mode == 0o700,
              let names = try? FileManager.default.contentsOfDirectory(atPath: paths.legacyState) else { return "unknown" }
        let known: Set = ["marker", "mullvad-before", "interface", "rules", "main-before", "mullvad-rules-before"]
        guard Set(names).isSubset(of: known), names.contains("marker"),
              names.allSatisfy({ SafeFiles.info(paths.legacyState + "/" + $0).kind == .regular }),
              (try? SafeFiles.read(paths.legacyState + "/marker")) == "codex-vpn-coexist-v1\n" else { return "unknown" }
        return "recognized"
    }

    private func resolverDirReason() -> String? {
        if SafeFiles.info(paths.resolverDir).kind == .absent { return nil }
        return SafeFiles.untrustedDirReason(paths.resolverDir, owner: paths.owner, base: paths.trustBase)
    }

    /// Resolver files (tailnet-domain names) with the given state. nil on enumeration error.
    private func resolverFiles(_ state: ResolverState) -> [String]? {
        if SafeFiles.info(paths.resolverDir).kind == .absent { return [] }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: paths.resolverDir) else { return nil }
        return names.filter { Validate.tailnetDomain($0) && ResolverState.of(paths.resolver($0)) == state }.sorted()
    }

    private func flushAnchorVerified(_ name: String) -> Bool {
        let f = sys.pfctl(["-a", name, "-F", "rules"])
        if !f.ok { note("BŁĄD: pfctl -F dla \(name): \(f.err.trimmingCharacters(in: .whitespacesAndNewlines))") }
        guard let after = readAnchor(name) else { note("BŁĄD: nie można odczytać \(name) po czyszczeniu"); return false }
        if !after.isEmpty { note("BŁĄD: \(name) nadal zawiera \(after.count) reguł"); return false }
        return true
    }

    /// Moves recognised prototype resolvers to backups. Returns (failed, changed).
    private func backupLegacyResolvers() -> (Bool, Bool) {
        guard let names = resolverFiles(.legacy) else { note("BŁĄD: nie można odczytać katalogu resolverów"); return (true, false) }
        var failed = false, changed = false
        for name in names {
            do {
                let b = try SafeFiles.moveToBackup(paths.resolver(name), backupDir: paths.backups, label: "resolver-\(name)")
                changed = true
                note("Resolver prototypu przeniesiony do \(b)")
            } catch { failed = true; note("BŁĄD: \(error)") }
        }
        return (failed, changed)
    }

    // MARK: - enable

    func enable(_ requested: Identity) throws {
        try withLock { try enableLocked(requested) }
    }

    private func enableLocked(_ requested: Identity) throws {
        guard requested.fieldsValid else { throw FSError("odrzucono nieprawidłowe parametry") }
        guard SafeFiles.info(paths.uninstalling).kind == .absent else {
            throw FSError("TailBridge jest odinstalowywany lub odinstalowany; zainstaluj pomocnika ponownie")
        }
        if let m = readCleanup() {
            let t = teardownLocked(reason: m.reason, includeLegacy: m.includeLegacy, ownToo: m.own)
            guard !t.failed else { throw FSError("wcześniejsze czyszczenie nadal się nie powiodło; nic nie włączono") }
        }
        let addrs = sys.interfaces()
        guard let loc = Interfaces.locate(ip4: requested.ip4, ip6: requested.ip6, in: addrs), loc.name == requested.iface else {
            throw FSError("adresy Tailscale nie znajdują się dokładnie na \(requested.iface)")
        }
        var id = requested
        id.index = loc.index
        if let p = Interfaces.problem(id, in: addrs) { throw FSError("tożsamość interfejsu: \(p)") }

        let info = sys.pfctl(["-s", "info"])
        switch info.ok ? PFRules.pfState(info.out) : .unreadable {
        case .enabled: break
        case .disabled: throw FSError("PF nie jest włączony; nic nie zmieniono")
        case .unreadable: throw FSError("nie można odczytać stanu PF; nic nie zmieniono")
        }
        switch PFRules.mainOrder(sys.pfctl(["-sr"])) {
        case .some(true): break
        case .some(false):
            throw FSError("brak anchor \"com.apple/*\" przed \"mullvad\"; globalne przeładowanie PF nie będzie wykonane")
        case .none: throw FSError("nie można odczytać reguł głównych PF; nic nie zmieniono")
        }
        // Policy: a non-empty Mullvad anchor means Mullvad's firewall has rules loaded (connected,
        // connecting or blocking), the only case the exception is for. Neither enable nor the monitor
        // checks the VPN connection itself: that would mean running a CLI from /Applications (writable by
        // admins) as root, and tearing down on every disconnect or reconnect would force a new password
        // prompt. The 4 rules only pass tailnet ranges on the Tailscale interface; they do not route
        // other traffic. The GUI requires a current Mullvad connection for Enable and for its green status.
        guard let mv = readAnchor("mullvad"), !mv.isEmpty else { throw FSError("anchor Mullvad jest pusty (Mullvad nie chroni?)") }

        guard let legacyLines = readAnchor(PFRules.legacyAnchor) else { throw FSError("nie można odczytać anchora prototypu") }
        let legacyIface = legacyLines.isEmpty ? nil : PFRules.legacyInterface(legacyLines)
        if !legacyLines.isEmpty && legacyIface == nil {
            throw FSError("anchor \(PFRules.legacyAnchor) zawiera nierozpoznane reguły; odmowa")
        }

        if SafeFiles.info(paths.resolverDir).kind == .absent { try SafeFiles.ensureDir(paths.resolverDir, mode: 0o755) }
        if let why = resolverDirReason() { throw FSError(why) }
        let resolverPath = paths.resolver(id.domain)
        let rs = ResolverState.of(resolverPath)
        if case .foreign(let why) = rs { throw FSError("\(resolverPath): \(why); odmowa nadpisania") }

        let desired = readDesired()
        guard let own = readAnchor(PFRules.anchor) else { throw FSError("nie można odczytać anchora TailBridge") }
        // Already enabled and verified: do not touch a working state.
        if desired == .valid(id), PFRules.classify(printed: own, expected: PFRules.expectedPrinted(id)) == .exact,
           rs == .ours, legacyLines.isEmpty {
            note("Już włączone; stan zweryfikowany, nic nie zmieniono")
            lastEvent = "ponowne włączenie: bez zmian"
            return
        }
        if desired != .absent && desired != .valid(id) {
            guard !teardownLocked(reason: "nowa tożsamość przed włączeniem", includeLegacy: false).failed else {
                throw FSError("nie udało się usunąć poprzedniego wyjątku")
            }
        }

        // Intent first: from here on the watchdog will roll back anything inconsistent.
        try SafeFiles.replaceAtomic(paths.desired, try json(id), mode: 0o644)
        var movedLegacyResolver: String?
        do {
            try SafeFiles.replaceAtomic(paths.rulesFile, PFRules.rules(id).joined(separator: "\n") + "\n", mode: 0o644)
            let load = sys.pfctl(["-a", PFRules.anchor, "-f", paths.rulesFile])
            guard load.ok else { throw FSError("pfctl nie załadował reguł: \(load.err.trimmingCharacters(in: .whitespacesAndNewlines))") }
            guard let printed = readAnchor(PFRules.anchor) else { throw FSError("nie można odczytać anchora po załadowaniu") }
            guard PFRules.classify(printed: printed, expected: PFRules.expectedPrinted(id)) == .exact else {
                throw FSError("anchor po załadowaniu różni się od oczekiwanego:\n" + printed.joined(separator: "\n"))
            }
            note("PF: 4 reguły na \(id.iface) zweryfikowane dokładnie")

            switch rs {
            case .legacy:
                let b = try SafeFiles.moveToBackup(resolverPath, backupDir: paths.backups, label: "resolver-\(id.domain)")
                movedLegacyResolver = b
                note("Resolver prototypu przeniesiony do \(b)")
                try SafeFiles.createExclusive(resolverPath, ResolverContent.ours, mode: 0o644)
            case .absent:
                try SafeFiles.createExclusive(resolverPath, ResolverContent.ours, mode: 0o644)
            case .ours, .foreign: break
            }
            guard ResolverState.of(resolverPath) == .ours else { throw FSError("resolver nie ma oczekiwanej treści") }
            note("Resolver \(resolverPath) → 100.100.100.100")

            if let li = legacyIface {
                guard flushAnchorVerified(PFRules.legacyAnchor) else { throw FSError("nie udało się usunąć szerokich reguł prototypu") }
                note("Usunięto 4 szerokie reguły prototypu (\(li))")
            }
            if legacyStateKind() == "recognized" {
                do {
                    let b = try SafeFiles.moveToBackup(paths.legacyState, backupDir: paths.backups, label: "codex-vpn-coexist-state")
                    note("Stan prototypu przeniesiony do \(b)")
                } catch { note("UWAGA: stan prototypu pozostawiony: \(error)") }
            }
            for w in sys.flushDNS() { note("UWAGA: \(w)") }
            lastEvent = "włączono na \(id.iface)"
        } catch {
            note("BŁĄD: \(error) — wycofywanie")
            let t = teardownLocked(reason: "wycofanie nieudanego włączenia", includeLegacy: false)
            // Put the adopted prototype resolver back so the pre-existing state is preserved.
            var restoreFailed = false
            if let b = movedLegacyResolver {
                let occupied = SafeFiles.info(resolverPath).kind != .absent
                if !occupied && rename(b, resolverPath) == 0 { note("Przywrócono resolver prototypu z \(b)"); _ = sys.flushDNS() }
                else {
                    restoreFailed = true
                    note("WYCOFANIE NIEPEŁNE — resolver prototypu nie został przywrócony (kopia: \(b)"
                         + (occupied ? "; ścieżka \(resolverPath) jest zajęta innym plikiem — nie nadpisano" : "")
                         + "). Po sprawdzeniu przywróć ręcznie: sudo cp '\(b)' '\(resolverPath)'")
                }
            }
            if t.failed { note("WYCOFANIE NIEPEŁNE — monitor ponawia czyszczenie; zob. docs/OPERATIONS.md") }
            if !t.failed && !restoreFailed { note("Wycofanie zakończone") }
            throw error
        }
    }

    // MARK: - teardown

    func teardown(reason: String, includeLegacy: Bool) throws -> Teardown {
        try withLock { teardownLocked(reason: reason, includeLegacy: includeLegacy) }
    }

    // MARK: - uninstall serialisation

    /// Must be called with the lock held. Blocks all later `enable` calls (also ones already waiting).
    func markUninstallingLocked() throws {
        try SafeFiles.replaceAtomic(paths.uninstalling, "TailBridge uninstall \(SafeFiles.timestamp())\n", mode: 0o644)
    }

    func clearUninstallMarkerLocked() throws {
        if SafeFiles.info(paths.uninstalling).kind != .absent && unlink(paths.uninstalling) != 0 {
            throw FSError("nie można usunąć znacznika odinstalowania \(paths.uninstalling)")
        }
    }

    /// Removes only owned/recognised state. Records a persistent marker first so the
    /// watchdog keeps retrying until every owned item is verifiably gone.
    @discardableResult
    func teardownLocked(reason: String, includeLegacy: Bool, ownToo: Bool = true) -> Teardown {
        var t = Teardown()
        let existing = readCleanup()
        let legacyScope = includeLegacy || (existing?.includeLegacy ?? false)
        let ownScope = ownToo || (existing?.own ?? false)
        // Keep the first reason (bounded) so repeated retries do not grow the marker.
        let escalates = existing.map { ownToo && !$0.own } ?? false
        let why = String(((escalates ? nil : existing?.reason) ?? reason).prefix(200))
        note(existing == nil ? "Usuwanie obejścia: \(why)" : "Ponowienie czyszczenia: \(why)")
        do {
            try SafeFiles.replaceAtomic(paths.cleanup, try json(CleanupMarker(includeLegacy: legacyScope, ownToo: ownScope, reason: why)), mode: 0o644)
        } catch { t.failed = true; note("BŁĄD: zapis znacznika czyszczenia: \(error)") }

        if ownScope && !flushAnchorVerified(PFRules.anchor) { t.failed = true }

        var resolverChanged = false
        if let why = resolverDirReason() {
            t.failed = true
            note("BŁĄD: katalog resolverów niezaufany (\(why)); resolverów nie ruszano")
        } else {
            if ownScope {
                if let names = resolverFiles(.ours) {
                    for name in names {
                        if unlink(paths.resolver(name)) == 0 { resolverChanged = true; note("Usunięto resolver \(name)") }
                        else { t.failed = true; note("BŁĄD: nie można usunąć resolvera \(name)") }
                    }
                } else { t.failed = true; note("BŁĄD: nie można odczytać katalogu resolverów") }
                if case .valid(let id) = readDesired(), case .foreign(let why) = ResolverState.of(paths.resolver(id.domain)) {
                    t.leftovers.append("\(paths.resolver(id.domain)) (\(why))")
                    note("UWAGA: \(paths.resolver(id.domain)) \(why) — pozostawiony bez zmian")
                }
            }
            if legacyScope {
                let (f, c) = backupLegacyResolvers()
                if f { t.failed = true }
                if c { resolverChanged = true }
            }
        }
        if legacyScope {
            if let lines = readAnchor(PFRules.legacyAnchor) {
                if lines.isEmpty {
                } else if PFRules.legacyInterface(lines) != nil {
                    if flushAnchorVerified(PFRules.legacyAnchor) { note("Usunięto reguły prototypu") } else { t.failed = true }
                } else {
                    t.leftovers.append("\(PFRules.legacyAnchor): \(lines.count) nierozpoznanych reguł")
                    note("UWAGA: anchor prototypu ma nierozpoznane reguły — pozostawiony")
                }
            } else { t.failed = true; note("BŁĄD: nie można odczytać anchora prototypu") }
        }

        if !t.failed {
            let owned = ownScope ? [(paths.desired, "zapisu zamiaru"), (paths.rulesFile, "pliku reguł")] : []
            for (p, what) in owned where SafeFiles.info(p).kind != .absent {
                if unlink(p) != 0 { t.failed = true; note("BŁĄD: nie można usunąć \(what)") }
            }
            // The marker goes last and only after everything else is gone, so nothing owed is forgotten.
            if !t.failed, SafeFiles.info(paths.cleanup).kind != .absent, unlink(paths.cleanup) != 0 {
                t.failed = true; note("BŁĄD: nie można usunąć znacznika czyszczenia")
            }
        } else {
            note("Znacznik czyszczenia zachowany: monitor ponowi próbę")
        }
        if resolverChanged { for w in sys.flushDNS() { note("UWAGA: \(w)") } }
        lastEvent = t.failed ? "wyłączanie NIEPEŁNE: \(why)"
            : (t.leftovers.isEmpty ? "wyłączono: \(why)" : "wyłączono; pozostawiono nierozpoznane elementy: \(why)")
        return t
    }

    // MARK: - watchdog

    /// One reconciliation pass. Never adds anything; only removes stale or unverifiable state.
    func tickLocked() {
        let addrs = sys.interfaces()
        let marker = readCleanup()
        // Both scopes are evaluated independently on every pass, whatever cleanup is already owed.
        var ownReason: String?
        if marker?.own != true {
            let own = readAnchor(PFRules.anchor)
            switch readDesired() {
            case .valid(let id):
                ownReason = Interfaces.problem(id, in: addrs) ?? inconsistency(id, own: own)
            case .corrupt:
                ownReason = "uszkodzony zapis zamiaru"
            case .absent:
                if own == nil || own?.isEmpty == false || resolverFiles(.ours)?.isEmpty != true {
                    ownReason = "elementy bez zapisanego zamiaru"
                }
            }
        }
        // Prototype rules pinned to a utun that no longer carries Tailscale addresses are stale;
        // they are removed together with the prototype resolver.
        var legacyReason: String?
        if marker?.includeLegacy != true, let lines = readAnchor(PFRules.legacyAnchor),
           let li = PFRules.legacyInterface(lines), !Interfaces.tailscaleCandidates(addrs).contains(li) {
            legacyReason = "nieaktualny prototyp (\(li))"
        }
        let ownScope = (marker?.own ?? false) || ownReason != nil
        let legacyScope = (marker?.includeLegacy ?? false) || legacyReason != nil
        guard ownScope || legacyScope else { return }
        teardownLocked(reason: ownReason ?? legacyReason ?? marker?.reason ?? "ponowienie",
                       includeLegacy: legacyScope, ownToo: ownScope)
    }

    /// Any observation that makes an enabled state unsafe or unverifiable (fail closed).
    private func inconsistency(_ id: Identity, own: [String]?) -> String? {
        guard let own = own else { return "nie można odczytać anchora" }
        switch PFRules.classify(printed: own, expected: PFRules.expectedPrinted(id)) {
        case .exact: break
        case .empty: return "anchor pusty (przeładowanie PF lub restart?)"
        case .mismatch: return "anchor niezgodny"
        }
        let info = sys.pfctl(["-s", "info"])
        switch info.ok ? PFRules.pfState(info.out) : .unreadable {
        case .enabled: break
        case .disabled: return "PF wyłączony (reguły mogłyby wrócić po jego włączeniu)"
        case .unreadable: return "nie można odczytać stanu PF"
        }
        switch PFRules.mainOrder(sys.pfctl(["-sr"])) {
        case .some(true): break
        case .some(false): return "com.apple/* nie jest przed mullvad"
        case .none: return "nie można odczytać reguł głównych"
        }
        let r = ResolverState.of(paths.resolver(id.domain))
        guard r == .ours else { return "resolver: \(r.label)" }
        return nil
    }

    func tick() throws -> HelperStatus {
        try withLock {
            tickLocked()
            return try writeStatusLocked(source: "watch")
        }
    }

    // MARK: - observation

    func observeLocked(source: String) -> HelperStatus {
        var problems: [String] = []
        let desired = readDesired()
        var identity: Identity?
        if case .valid(let id) = desired { identity = id }
        if desired == .corrupt { problems.append("uszkodzony zapis zamiaru") }
        let own = readAnchor(PFRules.anchor)
        var anchor = "error"
        if let own = own {
            if let id = identity { anchor = PFRules.classify(printed: own, expected: PFRules.expectedPrinted(id)).rawValue }
            else { anchor = own.isEmpty ? "empty" : "mismatch" }
        }
        let info = sys.pfctl(["-s", "info"])
        let pfOn: Bool?
        switch info.ok ? PFRules.pfState(info.out) : .unreadable {
        case .enabled: pfOn = true
        case .disabled: pfOn = false
        case .unreadable: pfOn = nil
        }
        let order = PFRules.mainOrder(sys.pfctl(["-sr"]))
        var legacy = "error"
        if let l = readAnchor(PFRules.legacyAnchor) {
            legacy = l.isEmpty ? "empty" : (PFRules.legacyInterface(l) != nil ? "recognized" : "unknown")
        }
        let resolver = identity.map { ResolverState.of(paths.resolver($0.domain)).label } ?? "n/a"
        if let id = identity, let p = Interfaces.problem(id, in: sys.interfaces()) { problems.append(p) }
        if identity != nil {
            if pfOn != true { problems.append(pfOn == nil ? "nie można odczytać stanu PF" : "PF wyłączony") }
            if order != true { problems.append(order == nil ? "nie można odczytać reguł głównych" : "com.apple/* nie jest przed mullvad") }
            if resolver != "ours" { problems.append("resolver: \(resolver)") }
            if anchor != "exact" { problems.append("anchor: \(anchor)") }
        }
        let pending = cleanupPending
        if pending { problems.append("czyszczenie w toku") }
        return HelperStatus(
            updatedAt: Date(), source: source,
            enabled: identity != nil && problems.isEmpty,
            identity: identity, anchor: anchor, pfEnabled: pfOn, appleBeforeMullvad: order,
            resolver: resolver, legacyAnchor: legacy, legacyState: legacyStateKind(),
            cleanupPending: pending, lastEvent: lastEvent, problems: problems)
    }

    @discardableResult
    func writeStatusLocked(source: String) throws -> HelperStatus {
        let st = observeLocked(source: source)
        try SafeFiles.replaceAtomic(paths.status, try json(st), mode: 0o644)
        return st
    }
}
