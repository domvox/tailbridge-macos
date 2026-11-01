import Foundation
import Network

/// User-side, read-only observation and diagnostics. Never mutates network state.
enum Tools {
    static let tailscale = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
    static let mullvad = "/Applications/Mullvad VPN.app/Contents/Resources/mullvad"
    static let curl = "/usr/bin/curl"
    static let ping = "/sbin/ping"
    static let dig = "/usr/bin/dig"
    static let launchctl = "/bin/launchctl"

    /// The App Store Tailscale binary acts as a CLI only when TERM is set; otherwise it tries to start its GUI.
    static var userEnv: [String: String] {
        ["HOME": NSHomeDirectory(), "USER": NSUserName(), "TMPDIR": NSTemporaryDirectory(), "TERM": "dumb"]
    }

    /// Runs an app-bundled CLI only if it is a root-owned, non-writable regular file.
    static func runVendor(_ exe: String, _ args: [String], timeout: TimeInterval = 10) -> ProcResult {
        let i = SafeFiles.info(exe)
        guard i.kind == .regular, i.uid == 0, i.mode & 0o022 == 0 else {
            return ProcResult(status: -1, out: "", err: "\(exe): missing or unsafe permissions")
        }
        return Proc.run(exe, args, timeout: timeout, extraEnv: userEnv)
    }
}

/// Mullvad's DNS content blockers, read from `mullvad dns get`. TailBridge never changes them.
enum MullvadDNS {
    /// Names of the content blockers Mullvad applies ("Ads", "Trackers", …); [] when none is on or a
    /// custom DNS server is set (Mullvad then uses that server instead). nil when the output isn't recognized.
    static func activeBlockers(_ out: String) -> [String]? {
        var custom: Bool?, blockers: [String] = [], sawBlocker = false
        for raw in out.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces).lowercased()
            if key == "Custom DNS" {
                if value == "yes" || value == "true" { custom = true } else if value == "no" || value == "false" { custom = false }
            } else if key.hasPrefix("Block "), value == "true" || value == "false" {
                sawBlocker = true
                if value == "true" {
                    let name = key.dropFirst("Block ".count)
                    blockers.append(name.prefix(1).uppercased() + name.dropFirst())
                }
            }
        }
        // With a custom server Mullvad lists the servers instead of the blockers.
        guard let c = custom else { return nil }
        if c { return [] }
        return sawBlocker ? blockers : nil
    }
}

/// Tailnet devices for the Connection Test picker. Parsed in-process; only name, IPv4 and Online are kept.
enum PeerList {
    static func load() -> [Peer]? {
        let r = Tools.runVendor(Tools.tailscale, ["status", "--json"])
        return r.ok ? Parsers.peers(r.out) : nil
    }
}

struct Snapshot {
    var taken = false          // false until the first read finishes
    var mullvadState = ""
    var mullvadError: String?
    var mullvadConnected = false
    var lockdown: String?
    /// Active Mullvad DNS content blockers; nil when unknown.
    var mullvadDNSBlockers: [String]?
    var ts: TailscaleSelf?
    var iface: (name: String, index: UInt32)?
    var env: EnvFile.State = .absent
    var resolver: ResolverState?
    var helperInstalled = false
    var monitorRunning = false
    var status: HelperStatus?
    var statusAge: TimeInterval?

    static func take() -> Snapshot {
        var s = Snapshot()
        s.taken = true
        let mv = Tools.runVendor(Tools.mullvad, ["status"])
        if mv.ok { s.mullvadState = Parsers.mullvadState(mv.out); s.mullvadConnected = Parsers.mullvadConnected(mv.out) }
        else { s.mullvadError = String(mv.err.prefix(80)) }
        let ld = Tools.runVendor(Tools.mullvad, ["lockdown-mode", "get"])
        if ld.ok { s.lockdown = ld.lines.first.map { String($0.prefix(100)) } }
        let dns = Tools.runVendor(Tools.mullvad, ["dns", "get"])
        if dns.ok { s.mullvadDNSBlockers = MullvadDNS.activeBlockers(dns.out) }
        let ts = Tools.runVendor(Tools.tailscale, ["status", "--json", "--peers=false"])
        if ts.ok { s.ts = Parsers.tailscaleSelf(ts.out) }
        if let t = s.ts, let v4 = t.ip4, let v6 = t.ip6 {
            s.iface = Interfaces.locate(ip4: v4, ip6: v6, in: Interfaces.snapshot())
        }
        if let d = s.ts?.domain { s.resolver = ResolverState.of("/private/etc/resolver/" + d) }
        s.env = EnvFile.standard().state()
        let h = SafeFiles.info(Privileged.helperPath)
        s.helperInstalled = h.kind == .regular && h.uid == 0 && h.mode & 0o022 == 0
        let lc = Proc.run(Tools.launchctl, ["print", "system/\(Privileged.label)"], timeout: 5)
        s.monitorRunning = lc.ok && lc.lines.contains("state = running")
        if let txt = try? SafeFiles.read(Privileged.base + "/status.json"),
           SafeFiles.info(Privileged.base + "/status.json").uid == 0,
           let st = try? Engine.decoder.decode(HelperStatus.self, from: Data(txt.utf8)) {
            s.status = st
            s.statusAge = Date().timeIntervalSince(st.updatedAt)
        }
        return s
    }

    var monitorFresh: Bool { monitorRunning && (statusAge ?? .infinity) < 15 }

    /// TailBridge's own exception is reported in place only from a fresh root observation that matches
    /// what we see now. It says nothing about Mullvad: the root helper observes only PF and the resolver.
    /// The green "On" headline additionally needs a current Mullvad connection (Presentation.swift).
    var workaroundActive: Bool {
        guard monitorFresh, let st = status, st.enabled, st.problems.isEmpty, !st.cleanupPending,
              st.anchor == "exact", st.pfEnabled == true, st.appleBeforeMullvad == true, st.resolver == "ours",
              let id = st.identity, let i = iface, let t = ts else { return false }
        return id.iface == i.name && id.index == i.index && id.ip4 == t.ip4 && id.ip6 == t.ip6 && id.domain == t.domain
    }
}

enum Diagnostics {
    static func curlMullvad(_ fam: String) -> CheckResult {
        let r = Proc.run(Tools.curl, PublicIPCheck.curlArgs(fam), timeout: 15)
        return Parsers.mullvadCheck(curl: r, family: fam)
    }

    static func mullvad(_ fam: String) -> CheckResult { present(curlMullvad(fam), family: fam) }

    /// Same verdict as Parsers.mullvadCheck, with name and detail in the UI language.
    static func present(_ result: CheckResult, family fam: String) -> CheckResult {
        var r = result
        r.name = L("check.public", fam)
        switch r.verdict {
        case .pass:
            let server = r.detail.range(of: "(").map { String(r.detail[$0.lowerBound...]) }
            r.detail = L("check.viaMullvad") + (server.map { " " + $0 } ?? "")
        case .leak: r.detail = L("check.outsideMullvad", fam)
        case .unavailable: r.detail = L("check.noConnectivity", fam, fam)
        case .inconclusive where r.reason == .family: r.detail = L("check.otherVersion", fam, fam)
        default: r.detail = L("check.unrecognized")
        }
        return r
    }

    /// Detail for a run whose output may be cut short (timed out, or past the output limit), else nil.
    /// Such stdout can still hold a plausible answer printed before the failure, so it is never parsed.
    static func cutShort(_ r: ProcResult) -> String? {
        if r.timedOut { return L("check.timedOut") }
        if r.truncated { return L("check.commandFailed") }
        return nil
    }

    /// `dig +short @100.100.100.100`: Passed only after a clean exit with a Tailscale address.
    static func magicDirect(_ r: ProcResult, name f: String) -> CheckResult {
        let n = L("check.magicDirect")
        if let why = cutShort(r) ?? (r.ok ? nil : L("check.commandFailed")) { return CheckResult(name: n, verdict: .fail, detail: why) }
        let ips = r.lines.filter(Validate.isTailscaleAddress)
        return CheckResult(name: n, verdict: ips.isEmpty ? .fail : .pass,
                           detail: ips.isEmpty ? L("check.noAnswer") : "\(f) → \(ips.joined(separator: ", "))")
    }

    /// `tailscale ping --c 1`. A direct pong ends with exit 0. With only a DERP pong the CLI exits
    /// nonzero by design ("direct connection not established", default --until-direct), so a complete
    /// DERP answer stays Info whatever the status; Passed needs a direct pong and a clean exit.
    static func path(_ r: ProcResult) -> CheckResult {
        let n = L("check.path")
        if let why = cutShort(r) { return CheckResult(name: n, verdict: .fail, detail: why) }
        switch Parsers.tailscalePath(r.out) {
        case .derp(let reg): return CheckResult(name: n, verdict: .info, detail: L("check.pathDerp", reg))
        case .direct:
            return r.ok ? CheckResult(name: n, verdict: .pass, detail: L("check.pathDirect"))
                        : CheckResult(name: n, verdict: .fail, detail: L("check.commandFailed"))
        case .none: return CheckResult(name: n, verdict: .fail, detail: noPong(r))
        }
    }

    /// `tailscale ping --tsmp --c 1`: the CLI exits 0 after the first pong; Passed needs both.
    static func tsmp(_ r: ProcResult) -> CheckResult {
        let n = L("check.tsmp")
        if let why = cutShort(r) { return CheckResult(name: n, verdict: .fail, detail: why) }
        if r.ok && Parsers.tsmpPong(r.out) { return CheckResult(name: n, verdict: .pass, detail: L("check.tsmpDetail")) }
        return CheckResult(name: n, verdict: .fail, detail: Parsers.tsmpPong(r.out) ? L("check.commandFailed") : noPong(r))
    }

    /// No pong: the CLI's own "no reply" (or a clean exit) is a negative answer; any other error is a failed command.
    private static func noPong(_ r: ProcResult) -> String {
        r.ok || r.err.contains("no reply") ? L("check.noPong") : L("check.commandFailed")
    }

    static func resolveSystem(_ host: String, timeout: TimeInterval = 6) -> [String]? {
        var result: [String]?
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                                 ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
            var res: UnsafeMutablePointer<addrinfo>?
            var list: [String] = []
            if getaddrinfo(host, nil, &hints, &res) == 0 {
                var p = res
                while let a = p {
                    var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(a.pointee.ai_addr, a.pointee.ai_addrlen, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 {
                        list.append(String(cString: buf))
                    }
                    p = a.pointee.ai_next
                }
                freeaddrinfo(res)
            }
            result = list
            sem.signal()
        }
        return sem.wait(timeout: .now() + timeout) == .timedOut ? nil : result
    }

    static func tcp(_ host: String, _ port: UInt16, timeout: TimeInterval = 6) -> (Bool, String) {
        let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let sem = DispatchSemaphore(value: 0)
        var outcome = (false, L("check.timedOut"))
        let lock = NSLock()
        conn.stateUpdateHandler = { st in
            lock.lock(); defer { lock.unlock() }
            switch st {
            case .ready: outcome = (true, L("check.tcpConnected")); sem.signal()
            case .failed(let e): outcome = (false, "\(e)"); sem.signal()
            case .waiting(let e): outcome = (false, L("check.waiting", "\(e)")); sem.signal()
            default: break
            }
        }
        conn.start(queue: .global())
        _ = sem.wait(timeout: .now() + timeout)
        conn.cancel()
        lock.lock(); defer { lock.unlock() }
        return outcome
    }

    /// Runs all checks concurrently. `peer` must be a Tailscale IPv4; `name` a MagicDNS host label.
    static func runAll(peer: String, name: String, port: UInt16, snapshot s: Snapshot) -> [CheckResult] {
        var results: [Int: CheckResult] = [:]
        let lock = NSLock()
        let group = DispatchGroup()
        func job(_ i: Int, _ f: @escaping () -> CheckResult) {
            group.enter()
            DispatchQueue.global().async {
                let r = f()
                lock.lock(); results[i] = r; lock.unlock()
                group.leave()
            }
        }
        let peerOK = Validate.tailscaleIPv4(peer)
        let domain = s.ts?.domain
        let fqdn = (Validate.hostLabel(name) && domain != nil) ? "\(name).\(domain!)" : nil

        job(0) { mullvad("IPv4") }
        job(1) { mullvad("IPv6") }
        job(2) { CheckResult(name: L("check.dnsLeak"), verdict: .notVerified, detail: L("check.dnsLeakDetail")) }
        job(3) {
            let n = L("check.magicSystem")
            guard let f = fqdn else { return CheckResult(name: n, verdict: .notVerified, detail: L("check.needName")) }
            guard let addrs = resolveSystem(f) else { return CheckResult(name: n, verdict: .fail, detail: L("check.nameTimedOut", f)) }
            let ts = addrs.filter(Validate.isTailscaleAddress)
            return CheckResult(name: n, verdict: ts.isEmpty ? .fail : .pass,
                               detail: ts.isEmpty ? L("check.noTailscaleAddress", f) : "\(f) → \(ts.joined(separator: ", "))")
        }
        job(4) {
            let n = L("check.magicDirect")
            guard let f = fqdn else { return CheckResult(name: n, verdict: .notVerified, detail: L("check.needName")) }
            return magicDirect(Proc.run(Tools.dig, ["+short", "+time=2", "+tries=1", "@100.100.100.100", f, "A"], timeout: 8), name: f)
        }
        job(5) {
            let n = L("check.ping")
            guard peerOK else { return CheckResult(name: n, verdict: .notVerified, detail: L("check.needPeer")) }
            let r = Proc.run(Tools.ping, ["-n", "-c", "1", "-W", "3000", peer], timeout: 8)
            return CheckResult(name: n, verdict: r.ok ? .pass : .fail, detail: r.ok ? L("check.replyFrom", peer) : L("check.noReply"))
        }
        job(6) {
            let n = L("check.tcp", Int(port))
            guard peerOK else { return CheckResult(name: n, verdict: .notVerified, detail: L("check.needPeer")) }
            let (ok, d) = tcp(peer, port)
            return CheckResult(name: n, verdict: ok ? .pass : .fail, detail: d)
        }
        job(7) {
            let n = L("check.path")
            guard peerOK else { return CheckResult(name: n, verdict: .notVerified, detail: L("check.needPeer")) }
            return path(Tools.runVendor(Tools.tailscale, ["ping", "--c", "1", "--timeout", "5s", peer], timeout: 12))
        }
        job(8) {
            let n = L("check.tsmp")
            guard peerOK else { return CheckResult(name: n, verdict: .notVerified, detail: L("check.needPeer")) }
            return tsmp(Tools.runVendor(Tools.tailscale, ["ping", "--tsmp", "--c", "1", "--timeout", "5s", peer], timeout: 12))
        }
        job(9) { CheckResult(name: L("check.failover"), verdict: .notVerified, detail: L("check.failoverDetail")) }
        group.wait()
        return (0...9).compactMap { results[$0] }
    }
}
