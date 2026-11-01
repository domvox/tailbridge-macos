import Foundation

enum Verdict: String {
    case pass = "OK"
    case fail = "BŁĄD"
    case leak = "WYCIEK"
    case unavailable = "NIEDOSTĘPNE"
    case notVerified = "NIESPRAWDZONE"
    case info = "INFO"
    /// The check ran but its data can't settle it either way (e.g. the server saw another IP version).
    case inconclusive = "NIEROZSTRZYGNIĘTE"
}

/// Why a check is inconclusive, so the UI can explain it without parsing Core's text.
enum InconclusiveReason: Equatable { case family, response }

struct CheckResult {
    var name: String
    var verdict: Verdict
    var detail: String
    var reason: InconclusiveReason? = nil
}

/// IP version of an address string. An IPv4-mapped IPv6 address (::ffff:a.b.c.d) is IPv4 traffic.
enum AddressFamily: Equatable { case ipv4, ipv4Mapped, ipv6 }

/// Public-IP check against Mullvad's per-family endpoints, the ones the Mullvad daemon itself
/// uses (mullvad-daemon/src/geoip.rs). am.i.mullvad.net has no AAAA record, so `curl -6` against
/// it can reach the server over IPv4 through an IPv4-mapped address.
enum PublicIPCheck {
    static let marker = "tailbridge-curl:"

    static func url(_ family: String) -> String {
        family == "IPv4" ? "https://ipv4.am.i.mullvad.net/json" : "https://ipv6.am.i.mullvad.net/json"
    }

    /// `-q` must stay first: it is the only way to keep curl from reading ~/.curlrc, which curl finds
    /// through the password database even without HOME. `--noproxy *` turns off every proxy
    /// (environment and config). The write-out line reports the HTTP status and the address curl
    /// actually connected to.
    static func curlArgs(_ family: String) -> [String] {
        ["-q", family == "IPv4" ? "-4" : "-6", "--noproxy", "*", "-sS",
         "--connect-timeout", "5", "--max-time", "10", "--proto", "=https",
         "-w", "\\n\(marker)%{http_code} %{remote_ip}", url(family)]
    }
}

struct TailscaleSelf: Equatable {
    var backendState: String
    var online: Bool
    var ip4: String?
    var ip6: String?
    var domain: String?
}

/// One tailnet device for the "Sprawdź" target picker. Only these three fields are read.
struct Peer: Equatable {
    var name: String
    var ip4: String
    var online: Bool
}

enum Parsers {
    /// First line of `mullvad status`: Connected / Connecting / Disconnected / Blocked: ...
    static func mullvadState(_ out: String) -> String {
        let first = out.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let t = first.trimmingCharacters(in: .whitespaces)
        return String(t.prefix(80))
    }

    static func mullvadConnected(_ out: String) -> Bool { mullvadState(out) == "Connected" }

    /// Reads only the fields TailBridge needs from `tailscale status --json --peers=false`.
    static func tailscaleSelf(_ json: String) -> TailscaleSelf? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let state = obj["BackendState"] as? String else { return nil }
        let me = obj["Self"] as? [String: Any]
        let ips = (me?["TailscaleIPs"] as? [String]) ?? []
        var domain = obj["MagicDNSSuffix"] as? String
        if let d = domain, !Validate.tailnetDomain(d) { domain = nil }
        return TailscaleSelf(backendState: String(state.prefix(40)),
                             online: (me?["Online"] as? Bool) ?? false,
                             ip4: ips.first(where: Validate.tailscaleIPv4),
                             ip6: ips.first(where: Validate.tailscaleIPv6),
                             domain: domain)
    }

    /// Reads only name (first DNSName label), first Tailscale IPv4 and Online for each peer of
    /// `tailscale status --json`. Everything else in the JSON is ignored and never stored.
    /// Online first, then by name; at most 500 entries.
    static func peers(_ json: String) -> [Peer] {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let map = obj["Peer"] as? [String: Any] else { return [] }
        var out: [Peer] = []
        for case let p as [String: Any] in map.values {
            guard let ip = ((p["TailscaleIPs"] as? [String]) ?? []).first(where: Validate.tailscaleIPv4) else { continue }
            let label = (p["DNSName"] as? String)?.split(separator: ".").first.map { String($0).lowercased() } ?? ""
            out.append(Peer(name: Validate.hostLabel(label) ? label : "", ip4: ip, online: (p["Online"] as? Bool) ?? false))
        }
        out.sort { a, b in
            if a.online != b.online { return a.online }
            if a.name != b.name { return a.name < b.name }
            return a.ip4 < b.ip4
        }
        return Array(out.prefix(500))
    }

    static func addressFamily(_ raw: String) -> AddressFamily? {
        let s = raw.lowercased()
        if Validate.ipv4Octets(s) != nil { return .ipv4 }
        guard s.count <= 45, Validate.full(s, "[0-9a-f:.]+") else { return nil }
        var a = in6_addr()
        guard inet_pton(AF_INET6, s, &a) == 1 else { return nil }
        let b = withUnsafeBytes(of: &a) { Array($0) }
        if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff { return .ipv4Mapped }
        return .ipv6
    }

    /// A JSON boolean only; JSONSerialization also bridges numbers 0/1 to Bool.
    private static func jsonBool(_ v: Any?) -> Bool? {
        guard let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
        return n.boolValue
    }

    /// Output of PublicIPCheck.curlArgs: the `/json` body, then curl's write-out line.
    /// Passed needs HTTP 200, a JSON object with an `ip` and a boolean `mullvad_exit_ip`, and both
    /// the address the server saw and the address curl connected to in the tested IP version.
    /// An IPv4-mapped address never counts as IPv6. The public IP itself is not kept.
    static func mullvadCheck(curl: ProcResult, family: String) -> CheckResult {
        let name = "Publiczny \(family)"
        func inconclusive(_ why: InconclusiveReason, _ d: String) -> CheckResult {
            CheckResult(name: name, verdict: .inconclusive, detail: d, reason: why)
        }
        if curl.timedOut || [6, 7, 28, 35, 45].contains(curl.status) {
            return CheckResult(name: name, verdict: .unavailable,
                               detail: "brak łączności \(family) (to nie jest dowód wycieku ani skutecznej ochrony)")
        }
        guard curl.ok else { return inconclusive(.response, "nierozpoznany błąd (curl \(curl.status))") }
        guard let nl = curl.out.range(of: "\n", options: .backwards) else {
            return inconclusive(.response, "brak wiersza diagnostycznego curl")
        }
        let tail = curl.out[nl.upperBound...].trimmingCharacters(in: .whitespaces)
        guard tail.hasPrefix(PublicIPCheck.marker) else { return inconclusive(.response, "brak wiersza diagnostycznego curl") }
        let fields = tail.dropFirst(PublicIPCheck.marker.count).split(separator: " ", omittingEmptySubsequences: false)
        guard fields.count == 2, fields[0] == "200" else { return inconclusive(.response, "odpowiedź HTTP inna niż 200") }
        guard let connected = addressFamily(String(fields[1])) else {
            return inconclusive(.response, "curl nie podał adresu połączenia")
        }
        let body = Data(curl.out[..<nl.lowerBound].utf8)
        guard let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let ip = obj["ip"] as? String, let seen = addressFamily(ip),
              let exit = jsonBool(obj["mullvad_exit_ip"]) else {
            return inconclusive(.response, "nierozpoznana lub niepełna odpowiedź")
        }
        let wanted: Set<AddressFamily> = family == "IPv4" ? [.ipv4, .ipv4Mapped] : [.ipv6]
        guard wanted.contains(seen), wanted.contains(connected) else {
            return inconclusive(.family, "serwer lub curl potwierdził inną wersję IP niż \(family)")
        }
        guard exit else { return CheckResult(name: name, verdict: .leak, detail: "ruch \(family) wychodzi poza Mullvad") }
        let host = (obj["mullvad_exit_ip_hostname"] as? String).flatMap { Validate.hostLabel($0) ? $0 : nil }
        return CheckResult(name: name, verdict: .pass, detail: "przez Mullvad" + (host.map { " (\($0))" } ?? ""))
    }

    enum PathKind: Equatable { case derp(String), direct, none }

    /// `tailscale ping` output: "pong from host (100.x) via DERP(xyz) in 30ms" or "... via 1.2.3.4:41641 in 5ms".
    static func tailscalePath(_ out: String) -> PathKind {
        for line in out.split(whereSeparator: \.isNewline) where line.hasPrefix("pong from") {
            guard let r = line.range(of: " via ") else { continue }
            let rest = line[r.upperBound...]
            if rest.hasPrefix("DERP(") , let close = rest.firstIndex(of: ")") {
                let region = rest[rest.index(rest.startIndex, offsetBy: 5)..<close]
                return .derp(Validate.hostLabel(String(region)) ? String(region) : "?")
            }
            return .direct
        }
        return .none
    }

    static func tsmpPong(_ out: String) -> Bool {
        out.split(whereSeparator: \.isNewline).contains { $0.hasPrefix("pong from") }
    }
}
