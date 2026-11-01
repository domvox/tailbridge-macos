import Foundation

// Presentation regression tests: pure mapping from a Snapshot to what the window shows.
// Built by build.sh from src/Core + src/App/{Checks,Presentation,Strings}.swift. Runs from the repo root.
// No system commands: Snapshot values are constructed directly, Snapshot.take() is never called.
// Outside the .app bundle L() returns the key itself, so expectations are written with L(...) too.

var failures = 0
var passes = 0
func check(_ cond: @autoclosure () -> Bool, _ msg: @autoclosure () -> String, line: Int = #line) {
    if cond() { passes += 1 } else { failures += 1; print("FAIL [\(line)]: \(msg())") }
}
func section(_ s: String) { print("— \(s)") }

let id = Identity(iface: "utun9", index: 9, ip4: "100.64.1.2", ip6: "fd7a:115c:a1e0::1", domain: "example.ts.net")

/// Helper installed and reporting, Mullvad connected, Tailscale running, TailBridge off, PF ready.
func ready() -> Snapshot {
    var s = Snapshot()
    s.taken = true
    s.helperInstalled = true
    s.monitorRunning = true
    s.statusAge = 1
    s.mullvadConnected = true
    s.mullvadState = "Connected"
    s.ts = TailscaleSelf(backendState: "Running", online: true, ip4: id.ip4, ip6: id.ip6, domain: id.domain)
    s.iface = (id.iface, id.index)
    s.resolver = .absent
    s.status = HelperStatus(updatedAt: Date(), source: "fixture", enabled: false, identity: nil, anchor: "empty",
                            pfEnabled: true, appleBeforeMullvad: true, resolver: "n/a", legacyAnchor: "empty",
                            legacyState: "absent", cleanupPending: false, lastEvent: "", problems: [])
    return s
}

func active() -> Snapshot {
    var s = ready()
    s.status!.enabled = true
    s.status!.identity = id
    s.status!.anchor = "exact"
    s.status!.resolver = "ours"
    s.resolver = .ours
    return s
}

/// Independent copy of the preconditions `enable()` in main.swift checks before asking for a password,
/// plus the helper's PF refusals (Engine.enable: PF on and readable, com.apple/* before mullvad and readable).
func enableWouldProceed(_ s: Snapshot) -> Bool {
    guard s.helperInstalled, s.monitorFresh, s.mullvadConnected,
          let t = s.ts, t.backendState == "Running", t.ip4 != nil, t.ip6 != nil, t.domain != nil, s.iface != nil
    else { return false }
    return s.status?.pfEnabled == true && s.status?.appleBeforeMullvad == true
}

func expectHeadline(_ name: String, _ s: Snapshot, _ state: Overall, _ title: String, _ action: PrimaryAction,
                    enabled: Bool, cleanup: Bool = false, detail: String? = nil, line: Int = #line) {
    let h = s.headline
    check(h.state == state && h.title == L(title) && h.action == action && h.actionEnabled == enabled && h.offersCleanup == cleanup,
          "\(name): got \(h.state) \(h.title) \(h.action) enabled=\(h.actionEnabled) cleanup=\(h.offersCleanup); expected \(state) \(L(title)) \(action) enabled=\(enabled) cleanup=\(cleanup)",
          line: line)
    if let d = detail { check(h.detail.hasPrefix(L(d)), "\(name): detail \(h.detail) should start with \(L(d))", line: line) }
}

section("nagłówek: stany")
expectHeadline("not taken", Snapshot(), .checking, "status.checking.title", .enable, enabled: false)
expectHeadline("active", active(), .active, "status.on.title", .disable, enabled: true)
do {
    var s = ready(); s.status!.cleanupPending = true
    expectHeadline("cleanup pending", s, .error, "status.error.title", .disable, enabled: true)
    for a in ["mismatch", "error"] {
        s = ready(); s.status!.anchor = a
        expectHeadline("anchor \(a)", s, .error, "status.error.title", .disable, enabled: true)
    }
    s = ready(); s.status!.identity = id
    expectHeadline("identity without active workaround", s, .attention, "status.stale.title", .disable, enabled: true)
    s = active(); s.status!.pfEnabled = false
    expectHeadline("active rules but PF off", s, .attention, "status.stale.title", .disable, enabled: true)
}

section("nagłówek: zielony tylko przy bieżącym połączeniu Mullvad (Daybreak #1)")
do {
    // The helper still reports its exact exception; only what the app sees of Mullvad/Tailscale changes.
    var s = active(); s.mullvadConnected = false; s.mullvadState = "Disconnected"
    expectHeadline("exception on, Mullvad disconnected", s, .attention, "status.stale.title", .disable, enabled: true, detail: "status.onNoMullvad.detail")
    s = active(); s.mullvadConnected = false; s.mullvadState = ""; s.mullvadError = "mullvad: daemon not running"
    expectHeadline("exception on, Mullvad status unavailable (backend offline)", s, .attention, "status.stale.title", .disable, enabled: true, detail: "status.onNoMullvad.detail")
    for state in ["Connecting", "Blocked: no relay", "Disconnecting", "Something new"] {
        s = active(); s.mullvadConnected = false; s.mullvadState = state
        expectHeadline("exception on, Mullvad \(state)", s, .attention, "status.stale.title", .disable, enabled: true, detail: "status.onNoMullvad.detail")
    }
    s = active(); s.mullvadConnected = false; s.mullvadState = "Disconnected"; s.lockdown = "Block traffic when the VPN is disconnected: on"
    expectHeadline("exception on, Mullvad disconnected with lockdown", s, .attention, "status.stale.title", .disable, enabled: true, detail: "status.onNoMullvad.detail")
    for state in ["Stopped", "Starting", "NeedsLogin"] {
        s = active(); s.ts!.backendState = state
        expectHeadline("exception on, Tailscale \(state)", s, .attention, "status.stale.title", .disable, enabled: true, detail: "status.onNoTailscale.detail")
    }
    s = active(); s.mullvadConnected = false; s.ts!.backendState = "Stopped"
    expectHeadline("Mullvad is reported before Tailscale", s, .attention, "status.stale.title", .disable, enabled: true, detail: "status.onNoMullvad.detail")
    // Tailscale's control-plane "Online" flag is not part of the gate: peers can work without it.
    s = active(); s.ts!.online = false
    expectHeadline("exception on, Tailscale running but control offline", s, .active, "status.on.title", .disable, enabled: true)
    // The exception itself is still reported as observed (Connection Test notice, technical details).
    s = active(); s.mullvadConnected = false
    check(s.workaroundActive, "workaroundActive still means: exception observed by the helper")
    check(s.technicalRows.contains { $0.label == L("tech.pf") && $0.tone == .ok }, "PF row still shows the exception")
}

section("nagłówek: brak pomocnika i nieaktualny monitor (regresja: brak Disable)")
do {
    var s = ready(); s.helperInstalled = false
    expectHeadline("no helper, nothing left", s, .attention, "status.setup.title", .enable, enabled: false, cleanup: false)
    for env in [EnvFile.State.ours, .legacy] {
        s = ready(); s.helperInstalled = false; s.env = env
        expectHeadline("no helper, env \(env) left", s, .attention, "status.setup.title", .enable, enabled: false, cleanup: true)
        check(s.headline.detail.contains(L("status.leftovers")), "no helper + env: detail mentions leftovers")
    }
    s = ready(); s.helperInstalled = false; s.env = .foreign("x")
    expectHeadline("no helper, foreign env is not ours to remove", s, .attention, "status.setup.title", .enable, enabled: false, cleanup: false)
    s = ready(); s.helperInstalled = false; s.resolver = .ours
    expectHeadline("no helper, resolver left", s, .attention, "status.setup.title", .enable, enabled: false, cleanup: true)

    s = ready(); s.statusAge = 15
    expectHeadline("monitor stale", s, .attention, "status.unknown.title", .disable, enabled: true, detail: "status.unknown.detail")
    s = ready(); s.monitorRunning = false
    expectHeadline("monitor not running", s, .attention, "status.unknown.title", .disable, enabled: true)
    s = ready(); s.status = nil; s.statusAge = nil
    expectHeadline("no status file", s, .attention, "status.unknown.title", .disable, enabled: true)
    s = active(); s.statusAge = 30
    expectHeadline("was active, monitor stale", s, .attention, "status.unknown.title", .disable, enabled: true)
}

section("nagłówek: wyłączony i gotowość Enable (regresja: Enable bez domeny/IP/PF)")
do {
    expectHeadline("ready", ready(), .off, "status.off.title", .enable, enabled: true, detail: "status.off.ready")
    var s = ready(); s.mullvadConnected = false; s.mullvadState = "Disconnected"
    expectHeadline("no Mullvad", s, .off, "status.off.title", .enable, enabled: false, detail: "status.off.needMullvad")
    s = ready(); s.ts = nil
    expectHeadline("no Tailscale", s, .off, "status.off.title", .enable, enabled: false, detail: "status.off.needTailscale")
    s = ready(); s.ts!.backendState = "Stopped"
    expectHeadline("Tailscale stopped", s, .off, "status.off.title", .enable, enabled: false, detail: "status.off.needTailscale")
    s = ready(); s.iface = nil
    expectHeadline("no interface", s, .off, "status.off.title", .enable, enabled: false, detail: "status.off.needTailscale")
    // Codex scratch failures 5 and 6: synthetic (take() cannot produce them), but Enable must still match enable()'s guard.
    s = ready(); s.ts!.ip6 = nil
    expectHeadline("no IPv6, interface kept", s, .off, "status.off.title", .enable, enabled: false, detail: "status.off.needTailscale")
    s = ready(); s.ts!.ip4 = nil
    expectHeadline("no IPv4, interface kept", s, .off, "status.off.title", .enable, enabled: false, detail: "status.off.needTailscale")
    // Codex scratch failure 1.
    s = ready(); s.ts!.domain = nil
    expectHeadline("no tailnet domain", s, .off, "status.off.title", .enable, enabled: false, detail: "status.off.needDomain")
    s = ready(); s.status!.pfEnabled = false
    expectHeadline("PF off", s, .off, "status.off.title", .enable, enabled: false, detail: "status.off.needPF")
    check(!s.headline.canEnable, "PF off: Actions → Enable disabled too")
    s = ready(); s.status!.pfEnabled = false; s.status!.appleBeforeMullvad = false
    expectHeadline("PF off wins over order", s, .off, "status.off.title", .enable, enabled: false, detail: "status.off.needPF")
    s = ready(); s.status!.appleBeforeMullvad = false
    expectHeadline("rule order", s, .off, "status.off.title", .enable, enabled: false, detail: "status.off.needOrder")
    // PF state unreadable (Core: pfEnabled nil) blocks Enable with its own message, never the "PF off" one.
    s = ready(); s.status!.pfEnabled = nil; s.status!.appleBeforeMullvad = nil
    expectHeadline("PF unreadable", s, .off, "status.off.title", .enable, enabled: false, detail: "status.off.pfUnreadable")
    check(!s.headline.canEnable, "PF unreadable: Actions → Enable disabled too")
    check(!s.headline.detail.contains(L("status.off.needPF")), "PF unreadable is not shown as PF off")
    s = ready(); s.status!.pfEnabled = nil
    expectHeadline("PF unreadable, order still read", s, .off, "status.off.title", .enable, enabled: false, detail: "status.off.pfUnreadable")
    s = ready(); s.status!.pfEnabled = nil; s.status!.appleBeforeMullvad = false
    expectHeadline("PF unreadable wins over order (helper checks PF first)", s, .off, "status.off.title", .enable, enabled: false, detail: "status.off.pfUnreadable")
    s = ready(); s.status!.appleBeforeMullvad = nil
    expectHeadline("main rules unreadable", s, .off, "status.off.title", .enable, enabled: false, detail: "status.off.pfUnreadable")
    check(!s.headline.canEnable, "main rules unreadable: Actions → Enable disabled too")
    s = ready(); s.status!.pfEnabled = false; s.status!.appleBeforeMullvad = nil
    expectHeadline("PF off wins over unreadable order", s, .off, "status.off.title", .enable, enabled: false, detail: "status.off.needPF")
    s = ready(); s.status!.pfEnabled = nil; s.resolver = .ours
    expectHeadline("PF unreadable keeps the cleanup Disable", s, .off, "status.off.title", .enable, enabled: false, cleanup: true, detail: "status.off.pfUnreadable")
    s = active(); s.status!.pfEnabled = nil; s.status!.appleBeforeMullvad = nil; s.status!.enabled = false
    expectHeadline("PF unreadable while TailBridge was on: Disable stays", s, .attention, "status.stale.title", .disable, enabled: true)
    s = ready(); s.status!.pfEnabled = nil; s.statusAge = 99
    expectHeadline("PF unreadable with a stale monitor: Disable stays", s, .attention, "status.unknown.title", .disable, enabled: true)

    s = ready(); s.env = .ours
    expectHeadline("env file while off is part of Enable, not a leftover", s, .off, "status.off.title", .enable, enabled: true, cleanup: false)
    s = ready(); s.resolver = .ours
    expectHeadline("resolver left while off", s, .off, "status.off.title", .enable, enabled: true, cleanup: true)
    s = ready(); s.status!.legacyAnchor = "recognized"
    expectHeadline("prototype rules left", s, .off, "status.off.title", .enable, enabled: true, cleanup: true)
    s = ready(); s.status!.legacyAnchor = "error"
    expectHeadline("prototype anchor unreadable is not a leftover", s, .off, "status.off.title", .enable, enabled: true, cleanup: false)
}

section("nagłówek: niezmienniki")
do {
    var all: [(String, Snapshot)] = [("not taken", Snapshot()), ("ready", ready()), ("active", active())]
    func add(_ n: String, _ f: (inout Snapshot) -> Void) { var s = ready(); f(&s); all.append((n, s)) }
    add("no mullvad") { $0.mullvadConnected = false }
    add("no ts") { $0.ts = nil }
    add("ts stopped") { $0.ts!.backendState = "Stopped" }
    add("no domain") { $0.ts!.domain = nil }
    add("no ip4") { $0.ts!.ip4 = nil }
    add("no ip6") { $0.ts!.ip6 = nil }
    add("no iface") { $0.iface = nil }
    add("pf off") { $0.status!.pfEnabled = false }
    add("order") { $0.status!.appleBeforeMullvad = false }
    add("pf unreadable") { $0.status!.pfEnabled = nil; $0.status!.appleBeforeMullvad = nil }
    add("order unreadable") { $0.status!.appleBeforeMullvad = nil }
    add("pf unreadable resolver") { $0.status!.pfEnabled = nil; $0.resolver = .ours }
    add("pf unreadable identity") { $0.status!.pfEnabled = nil; $0.status!.identity = id }
    add("no helper") { $0.helperInstalled = false }
    add("no helper env") { $0.helperInstalled = false; $0.env = .ours }
    add("stale") { $0.statusAge = 99 }
    add("identity") { $0.status!.identity = id }
    add("cleanup") { $0.status!.cleanupPending = true }
    add("mismatch") { $0.status!.anchor = "mismatch" }
    add("legacy") { $0.status!.legacyAnchor = "recognized" }
    add("resolver") { $0.resolver = .legacy }
    for (n, f) in [("active no mullvad", { (s: inout Snapshot) in s.mullvadConnected = false }),
                   ("active mullvad error", { (s: inout Snapshot) in s.mullvadConnected = false; s.mullvadError = "x" }),
                   ("active ts stopped", { (s: inout Snapshot) in s.ts!.backendState = "Stopped" })] {
        var s = active(); f(&s); all.append((n, s))
    }
    for (n, s) in all {
        let h = s.headline
        if h.action == .enable && h.actionEnabled {
            check(enableWouldProceed(s), "\(n): Enable is offered but enable()/helper would refuse")
        }
        // Actions → Enable uses canEnable; it must never ask for a password the helper would refuse.
        if h.canEnable { check(enableWouldProceed(s), "\(n): menu Enable allowed but enable()/helper would refuse") }
        check(h.canEnable == (h.action == .enable && h.actionEnabled), "\(n): menu Enable matches the primary button")
        if h.action == .disable { check(h.actionEnabled, "\(n): a primary Disable is always clickable") }
        if h.offersCleanup { check(h.action == .enable, "\(n): secondary Disable only next to Enable") }
        check(h.state != .active || s.workaroundActive, "\(n): On only when the workaround is verified active")
        check(h.state != .active || (s.mullvadConnected && s.tailscaleRunning), "\(n): On only with Mullvad connected and Tailscale running")
        check(!h.title.isEmpty && !h.detail.isEmpty, "\(n): title and detail present")
    }
    // Every state where TailBridge may still have changes in place offers Disable in the window.
    for n in ["active", "identity", "cleanup", "mismatch", "stale", "no helper env", "legacy", "resolver",
              "pf unreadable resolver", "pf unreadable identity", "active no mullvad", "active mullvad error", "active ts stopped"] {
        let s = all.first { $0.0 == n }!.1, h = s.headline
        check((h.action == .disable && h.actionEnabled) || h.offersCleanup, "\(n): Disable reachable from the window")
    }
}

section("szczegóły techniczne: PF (regresja: zielony status przy wyłączonym PF)")
// pf/order: true, false, or nil (Core could not read them). 4 × 3 × 3 = 36 combinations.
for anchor in ["exact", "empty", "mismatch", "error"] {
    for pf in [true, false, nil] as [Bool?] {
        for order in [true, false, nil] as [Bool?] {
            var s = ready(); s.status!.identity = anchor == "exact" ? id : nil
            s.status!.anchor = anchor; s.status!.pfEnabled = pf; s.status!.appleBeforeMullvad = order
            let row = s.technicalRows.first { $0.label == L("tech.pf") }!
            let key = ["exact": "tech.pfExact", "empty": "tech.pfEmpty", "mismatch": "tech.pfMismatch", "error": "tech.pfError"][anchor]!
            let base = anchor == "exact" ? L(key, id.iface) : L(key)
            let bad = anchor == "mismatch" || anchor == "error"
            let unreadable = pf == nil || (pf == true && order == nil)
            let text: String
            if unreadable { text = base + " · " + L("tech.pfUnreadable") }   // anchor state kept, it is read separately
            else if pf == false { text = base + " · " + L("tech.pfOff") }
            else if order == false { text = base + " · " + L("tech.pfOrder") }
            else { text = base }
            let desc = "\(anchor) pf=\(String(describing: pf)) order=\(String(describing: order))"
            check(row.value == text, "PF text \(desc): \(row.value) ≠ \(text)")
            let tone: Tone
            if bad { tone = .error }
            else if unreadable || pf == false { tone = .warning }   // Enable refused; not more severe than the header
            else if order == false { tone = .error }
            else { tone = anchor == "exact" ? .ok : .neutral }
            check(row.tone == tone, "PF tone \(desc): \(row.tone) ≠ \(tone)")
            check(!(row.tone == .ok && pf != true), "PF never green unless PF is read as on (\(desc))")
            if pf == nil { check(!row.value.contains(L("tech.pfOff")), "unreadable PF never shown as off (\(desc))") }
        }
    }
}
do {
    var s = ready(); s.statusAge = 99
    check(s.technicalRows.first { $0.label == L("tech.pf") }?.tone == .unknown, "PF unknown without a fresh monitor")
}

section("szczegóły techniczne: wiersze informacyjne i prototyp (regresja: mylące szare kółko)")
do {
    func row(_ s: Snapshot, _ key: String) -> DetailRow? { s.technicalRows.first { $0.label == L(key) } }
    for (name, s) in [("off", ready()), ("active", active())] {
        check(row(s, "tech.interface")?.tone == .info, "interface is information, not 'not set' (\(name))")
        check(row(s, "tech.addresses")?.tone == .info, "addresses are information, not 'not set' (\(name))")
        check(row(s, "tech.legacy")?.tone == .ok, "no prototype leftovers reads as OK (\(name))")
        check(row(s, "tech.legacy")?.value == L("tech.legacyNone"), "no prototype leftovers in plain words (\(name))")
    }
    check(Tone.info.symbol == "info.circle" && Tone.info.label == L("tone.info"), "info tone uses the 'i' icon and its own label")
    check(Tone.info.symbol != Tone.neutral.symbol, "info icon differs from 'not set'")

    var s = ready(); s.iface = nil
    check(row(s, "tech.interface")?.tone == .warning, "missing interface still warns")
    s = ready(); s.status!.legacyState = "recognized"
    check(row(s, "tech.legacy")?.tone == .neutral && row(s, "tech.legacy")?.value == L("tech.legacyValue", "empty", "recognized"),
          "prototype state file left: technical text, not 'No leftovers'")
    s = ready(); s.status!.legacyState = "unknown"
    check(row(s, "tech.legacy")?.value != L("tech.legacyNone"), "unknown prototype state is not 'No leftovers'")
    for a in ["recognized", "unknown", "error"] {
        s = ready(); s.status!.legacyAnchor = a
        check(row(s, "tech.legacy")?.tone == .warning && row(s, "tech.legacy")?.value != L("tech.legacyNone"),
              "prototype anchor \(a): warning, not 'No leftovers'")
    }
    s = ready(); s.statusAge = 99
    check(row(s, "tech.legacy")?.tone == .unknown, "prototype unknown without a fresh monitor")
}

section("Mullvad i Tailscale")
for (input, key) in [("Block traffic when the VPN is disconnected: on", "mullvad.lockdownOn"),
                     ("Block traffic when the VPN is disconnected: off", "mullvad.lockdownOff"),
                     ("Lockdown mode ON", "mullvad.lockdownOn"), ("unknown", "")] {
    var s = ready(); s.lockdown = input
    check(s.lockdownText == (key.isEmpty ? nil : L(key)), "lockdown \(input): \(String(describing: s.lockdownText))")
}
for (input, key, tone) in [("Connected", "mullvad.connected", Tone.ok), ("Disconnected", "mullvad.disconnected", .warning),
                           ("Connecting", "mullvad.connecting", .warning), ("Blocked: firewall error", "mullvad.blocked", .warning)] {
    var s = ready(); s.mullvadState = input
    check(s.mullvadLine.value == L(key) && s.mullvadLine.tone == tone, "Mullvad \(input)")
}
do {
    var s = ready(); s.mullvadError = "x"
    check(s.mullvadLine.value == L("mullvad.unavailable") && s.mullvadLine.tone == .warning, "Mullvad unavailable")
    check(Snapshot().mullvadLine.tone == .unknown && Snapshot().tailscaleLine.tone == .unknown, "checking lines")
}
for (state, key, tone) in [("Running", "tailscale.connected", Tone.ok), ("NeedsLogin", "tailscale.signedOut", .warning),
                           ("NeedsMachineAuth", "tailscale.needsApproval", .warning), ("Stopped", "tailscale.stopped", .warning),
                           ("Starting", "tailscale.starting", .unknown)] {
    var s = ready(); s.ts!.backendState = state
    check(s.tailscaleLine.value == L(key) && s.tailscaleLine.tone == tone, "Tailscale \(state)")
}
do {
    var s = ready(); s.ts = nil
    check(s.tailscaleLine.value == L("tailscale.unavailable"), "Tailscale absent")
    s = ready(); s.iface = nil
    check(s.tailscaleLine.tone == .warning && s.tailscaleLine.secondary == L("tailscale.noInterface"), "Tailscale without interface")
}

section("Mullvad: filtry DNS (możliwy konflikt z Tailscale)")
do {
    let allOff = "Custom DNS: no\nBlock ads: false\nBlock trackers: false\nBlock malware: false\nBlock adult content: false\nBlock gambling: false\nBlock social media: false\n"
    check(MullvadDNS.activeBlockers(allOff) == [], "real output, all blockers off")
    let some = allOff.replacingOccurrences(of: "ads: false", with: "ads: true")
        .replacingOccurrences(of: "trackers: false", with: "trackers: true")
        .replacingOccurrences(of: "malware: false", with: "malware: true")
        .replacingOccurrences(of: "gambling: false", with: "gambling: true")
    check(MullvadDNS.activeBlockers(some) == ["Ads", "Trackers", "Malware", "Gambling"], "active blockers named: \(String(describing: MullvadDNS.activeBlockers(some)))")
    check(MullvadDNS.activeBlockers(some.replacingOccurrences(of: "adult content: false", with: "adult content: true"))?.contains("Adult content") == true, "multi-word blocker name")
    check(MullvadDNS.activeBlockers(some.replacingOccurrences(of: "Custom DNS: no", with: "Custom DNS: yes")) == [], "custom DNS: blockers not applied")
    // Real custom-DNS output (mullvad-cli dns.rs): servers instead of blocker lines.
    check(MullvadDNS.activeBlockers("Custom DNS: yes\nServers:\n10.0.0.53\n") == [], "real custom-DNS output: no blockers")
    for bad in ["", "error: daemon not running", "Custom DNS: no\n", "Block ads: true\n"] {
        check(MullvadDNS.activeBlockers(bad) == nil, "unrecognized output: \(bad.debugDescription)")
    }

    var s = ready(); s.mullvadDNSBlockers = ["Ads", "Trackers"]
    check(s.dnsFilterWarning == L("mullvad.dnsFilterWarning", "Ads, Trackers"), "warning while connected with blockers on")
    s.mullvadConnected = false
    check(s.dnsFilterWarning == nil, "no warning while Mullvad is disconnected")
    s = ready(); s.mullvadDNSBlockers = []
    check(s.dnsFilterWarning == nil, "no warning without blockers")
    s = ready(); s.mullvadDNSBlockers = nil
    check(s.dnsFilterWarning == nil, "no warning when the setting is unknown")
    s = Snapshot(); s.mullvadConnected = true; s.mullvadDNSBlockers = ["Ads"]
    check(s.dnsFilterWarning == nil, "no warning before the first read")
    // A warning only: it never blocks Enable and never changes the headline.
    s = ready(); s.mullvadDNSBlockers = ["Ads"]
    expectHeadline("DNS blockers on: Enable unaffected", s, .off, "status.off.title", .enable, enabled: true, detail: "status.off.ready")
    s = active(); s.mullvadDNSBlockers = ["Ads"]
    expectHeadline("DNS blockers on: On unaffected", s, .active, "status.on.title", .disable, enabled: true)
}

section("przyczyny z Core i werdykty")
do {
    // Every `.foreign("…")` reason Core can produce is shown in the UI language.
    var reasons = Set<String>()
    let re = try! NSRegularExpression(pattern: #"\.foreign\("([^"]+)"\)"#)
    for f in (try? FileManager.default.contentsOfDirectory(atPath: "src/Core")) ?? [] where f.hasSuffix(".swift") {
        let text = (try? String(contentsOfFile: "src/Core/" + f, encoding: .utf8)) ?? ""
        for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            reasons.insert(String(text[Range(m.range(at: 1), in: text)!]))
        }
    }
    check(!reasons.isEmpty, "found Core foreign reasons")
    for r in reasons { check(foreignReason(r) != r, "Core reason has no English mapping: \(r)") }
    check(foreignReason("future") == "future", "unknown reason falls back to the original text")
    let all: [Verdict] = [.pass, .fail, .leak, .unavailable, .notVerified, .info, .inconclusive]
    check(Set(all.map { $0.label }).count == all.count, "verdict labels distinct")
    check(Set(all.map { $0.symbol }).count == all.count, "verdict symbols distinct (not color alone)")
}

section("komunikaty sekcji (regresja: nadpisywanie błędów i nieaktualne komunikaty)")
do {
    let err = NoticeState(.error, "failed")
    let e2 = err.adding(.warning, "unconfirmed")
    check(e2.kind == .error && e2.message == "failed\nunconfirmed", "follow-up never downgrades an error: \(e2)")
    let ok = NoticeState(.success, "on").adding(.warning, "problems")
    check(ok.kind == .warning && ok.message.hasPrefix("on\n"), "follow-up raises severity and keeps the first text")
    check(NoticeState(.info, "a").adding(.error, "b").kind == .error, "error follow-up wins")

    let posted = NoticeState(.error, "failed")
    check(posted.refreshed(context: "A", idle: false) == posted, "mid-action refresh keeps the message and does not adopt")
    let adopted = posted.refreshed(context: "A", idle: true)
    check(adopted?.context == "A", "first idle refresh adopts the state")
    check(adopted?.refreshed(context: "A", idle: true) == adopted, "same state keeps the message")
    check(adopted?.refreshed(context: "B", idle: true) == nil, "changed state hides the message")
    check(adopted?.refreshed(context: "B", idle: false) == adopted, "mid-action change does not hide the message")

    var a = ready(), b = ready()
    b.statusAge = 9; b.status!.updatedAt = Date(timeIntervalSinceNow: -9)
    check(a.headerContext == b.headerContext, "message context ignores the monitor's age")
    b = active()
    check(a.headerContext != b.headerContext, "message context changes Off → On")
    b = ready(); b.mullvadConnected = false
    check(a.headerContext != b.headerContext, "message context changes when Enable becomes unavailable")
    a.helperInstalled = false; b = ready()
    check(a.adminContext != b.adminContext, "admin context follows the helper")
}

section("test połączenia: urządzenie i aktualność wyników")
do {
    let peers = [Peer(name: "laptop", ip4: "100.64.0.1", online: true), Peer(name: "Phone", ip4: "100.64.0.2", online: false),
                 Peer(name: "other", ip4: "100.64.0.1", online: true)]
    check(matchingPeer(ip: "100.64.0.1", name: "laptop", in: peers) == 0, "IP and name match")
    check(matchingPeer(ip: " 100.64.0.2 ", name: "PHONE", in: peers) == 1, "trimmed, case-insensitive name, offline device")
    check(matchingPeer(ip: "100.64.0.1", name: "other", in: peers) == 2, "same IP, the name decides")
    check(matchingPeer(ip: "100.64.0.1", name: "", in: peers) == 0, "IP alone picks the first device")
    check(matchingPeer(ip: "100.64.0.2", name: "laptop", in: peers) == nil, "IP of one device with another's name is a custom target")
    check(matchingPeer(ip: "", name: "laptop", in: peers) == nil, "no IP, no device")
    check(matchingPeer(ip: "100.64.0.9", name: "", in: []) == nil, "no devices")

    check(testTarget(ip: " 100.64.0.1", name: "Laptop ", port: "22 ") == testTarget(ip: "100.64.0.1", name: "laptop", port: "22"),
          "target normalized like the test reads it")
    let run = TestRun(target: testTarget(ip: "100.64.0.1", name: "laptop", port: "22"), context: ready().headerContext)
    check(freshness(of: run, target: run.target, context: ready().headerContext) == .current, "same target and state: current")
    check(freshness(of: run, target: testTarget(ip: "100.64.0.2", name: "phone", port: "22"), context: run.context) == .targetChanged,
          "other device: stale")
    check(freshness(of: run, target: testTarget(ip: "100.64.0.1", name: "laptop", port: "443"), context: run.context) == .targetChanged,
          "other port: stale")
    check(freshness(of: run, target: run.target, context: active().headerContext) == .stateChanged, "state changed: stale")
}

section("test połączenia: podsumowanie")
do {
    func r(_ v: Verdict) -> CheckResult { CheckResult(name: "x", verdict: v, detail: "") }
    let mixed = [r(.pass), r(.pass), r(.fail), r(.leak), r(.notVerified), r(.unavailable), r(.info), r(.inconclusive)]
    let s = summarize(mixed, workaroundActive: true, hadPeer: true)
    check(s.passed == 2 && s.failed == 2 && s.notTested == 2 && s.inconclusive == 1, "counts (info not counted): \(s)")
    let unsure = [r(.pass), r(.inconclusive)]
    check(summarize(unsure, workaroundActive: true, hadPeer: true).noticeKey == "test.someInconclusive", "inconclusive warns, is not passed")
    check(summarize(unsure, workaroundActive: true, hadPeer: true).passed == 1, "inconclusive not counted as passed")
    check(summarize([r(.fail), r(.inconclusive)], workaroundActive: true, hadPeer: true).noticeKey == "test.someFailed", "failures before inconclusive")
    check(s.notice == .error && s.noticeKey == "test.leakFound", "leak first")
    let noLeak = [r(.pass), r(.fail)]
    check(summarize(noLeak, workaroundActive: false, hadPeer: true).noticeKey == "test.notActive", "then inactive workaround")
    check(summarize(noLeak, workaroundActive: true, hadPeer: false).noticeKey == "test.pickDevice", "then no device")
    check(summarize(noLeak, workaroundActive: true, hadPeer: true).noticeKey == "test.someFailed", "then failures")
    let clean = summarize([r(.pass), r(.info)], workaroundActive: true, hadPeer: true)
    check(clean.notice == nil && clean.noticeKey == nil, "all passed: no warning")
    check(summarize([], workaroundActive: true, hadPeer: true) == ResultSummary(passed: 0, failed: 0, notTested: 0), "empty")
}

section("test połączenia: zwinięta sekcja (podsumowanie w jednej linii)")
do {
    func r(_ v: Verdict) -> CheckResult { CheckResult(name: "x", verdict: v, detail: "") }
    func line(_ v: [Verdict], active: Bool = true, peer: Bool = true) -> StatusLine {
        collapsedTestLine(.results(summarize(v.map(r), workaroundActive: active, hadPeer: peer), at: "12:34"))
    }
    // Never green without a current, fully passed run.
    check(collapsedTestLine(.none).tone == .unknown && collapsedTestLine(.none).value == L("test.none"), "no test: unknown, not green")
    check(collapsedTestLine(.running).tone == .unknown && collapsedTestLine(.running).value == L("test.running"), "running: unknown")
    check(collapsedTestLine(.stale(at: "12:34")).tone == .warning, "stale results: attention, not green")
    check(line([]).tone == .info, "empty run: neutral, not green")
    check(line([.info]).tone == .info, "only information: neutral, not green")
    check(line([.pass, .info]).tone == .ok, "all passed, workaround on, device tested: green")
    check(line([.pass, .fail]).tone == .error, "failure: error")
    check(line([.pass, .leak]).tone == .error, "leak: error")
    check(line([.pass], active: false).tone == .warning, "inactive workaround: attention")
    check(line([.pass], peer: false).tone == .warning, "no device chosen: incomplete")
    check(line([.pass, .inconclusive]).tone == .warning, "inconclusive: attention")
    check(line([.pass, .notVerified]).tone == .info && line([.pass, .unavailable]).tone == .info, "passed + not tested: neutral, incomplete")
    check(line([.notVerified, .unavailable]).tone == .info && line([.notVerified]).help == L("verdict.notTested"), "nothing run: neutral Not tested")
    // Priority in mixed runs: failure/leak > inconclusive or notice > coverage gap > green.
    check(line([.pass, .fail, .notVerified]).tone == .error, "failure beats untested")
    check(line([.pass, .leak, .notVerified], active: false).tone == .error, "leak beats inactive workaround and untested")
    check(line([.pass, .fail, .inconclusive]).tone == .error, "failure beats inconclusive")
    check(line([.pass, .inconclusive, .notVerified]).tone == .warning, "inconclusive beats untested")
    check(line([.pass, .notVerified], active: false).tone == .warning, "inactive workaround not silenced by untested")
    check(line([.pass, .unavailable], peer: false).tone == .warning, "missing device not silenced by untested")
    check(line([.notVerified], active: false).tone == .warning, "inactive workaround warns even when nothing passed")
    check(line([.pass, .pass, .info]).tone == .ok, "only passes and information: green")
    for o in [TestOutcome.none, .running, .stale(at: "1"), .results(ResultSummary(passed: 0, failed: 0, notTested: 0), at: "1")] {
        check(collapsedTestLine(o).tone != .ok, "never green: \(o)")
        check(collapsedTestLine(o).help != nil, "status in words: \(o)")
    }
    // The green line names passed checks, never a generic "OK" that could read as "safe".
    check(line([.pass]).help == L("verdict.pass") && line([.pass]).help != Tone.ok.label, "green status word is Passed")
    check(collapsedTestLine(.none).help == L("verdict.notTested"), "no test spoken as Not tested")
    check(line([.pass, .notVerified]).help == L("test.partial") && line([.pass, .notVerified]).help != Tone.warning.label,
          "coverage gap spoken as Partly tested, not Needs attention")
    check(line([.pass, .fail, .notVerified]).help == Tone.error.label, "failure spoken as a problem")
    check(line([.pass, .inconclusive]).help == Tone.warning.label, "inconclusive spoken as needing attention")
    check(Tone.info.symbol == "info.circle" && Tone.info.color == .secondaryLabelColor, "coverage gap uses the neutral ⓘ style")

    // Formatted text with the real strings table: counts and the test time.
    stringsTableOverride = NSDictionary(contentsOfFile: "src/App/Resources/en.lproj/Localizable.strings") as? [String: String]
    defer { stringsTableOverride = nil }
    check(line([.pass, .fail, .notVerified]).value == "1 passed · 1 failed · 0 inconclusive · 1 not tested — 12:34",
          "results line: \(line([.pass, .fail, .notVerified]).value)")
    let stale = collapsedTestLine(.stale(at: "12:34")).value
    check(stale.contains("out of date") && stale.contains("12:34") && !stale.contains("passed"), "stale line: \(stale)")
    check(collapsedTestLine(.none).value == "No test run yet.", "no test line")
}

section("diagnostyka: Passed tylko po poprawnym zakończeniu polecenia (Daybreak #3)")
do {
    func res(_ out: String, status: Int32 = 0, err: String = "", timedOut: Bool = false, truncated: Bool = false) -> ProcResult {
        ProcResult(status: status, out: out, err: err, timedOut: timedOut, truncated: truncated)
    }
    let f = "peer.example.ts.net"
    let digOut = "100.64.1.9\n"
    let directPong = "pong from peer (100.64.1.9) via 192.0.2.10:41641 in 12ms\n"
    let derpPong = "pong from peer (100.64.1.9) via DERP(fra) in 40ms\n"
    let tsmpPong = "pong from peer (100.64.1.9, 41641) via TSMP in 9ms\n"
    func expect(_ name: String, _ r: CheckResult, _ v: Verdict, _ detail: String? = nil, line: Int = #line) {
        check(r.verdict == v && (detail == nil || r.detail == L(detail!)), "\(name): \(r.verdict) \(r.detail); expected \(v) \(detail ?? "")", line: line)
    }
    // Valid output.
    expect("dig ok", Diagnostics.magicDirect(res(digOut), name: f), .pass)
    check(Diagnostics.magicDirect(res(digOut), name: f).detail == "\(f) → 100.64.1.9", "dig ok: detail lists the address")
    expect("dig ok, no answer (NXDOMAIN)", Diagnostics.magicDirect(res(""), name: f), .fail, "check.noAnswer")
    expect("path direct ok", Diagnostics.path(res(directPong)), .pass, "check.pathDirect")
    expect("tsmp ok", Diagnostics.tsmp(res(tsmpPong)), .pass, "check.tsmpDetail")
    // Plausible stdout, then a nonzero exit.
    expect("dig answer + nonzero", Diagnostics.magicDirect(res(digOut, status: 9), name: f), .fail, "check.commandFailed")
    expect("path direct pong + nonzero", Diagnostics.path(res(directPong, status: 1, err: "some error")), .fail, "check.commandFailed")
    expect("tsmp pong + nonzero", Diagnostics.tsmp(res(tsmpPong, status: 1)), .fail, "check.commandFailed")
    // Timed out (including a leftover process holding the output).
    expect("dig answer + timeout", Diagnostics.magicDirect(res(digOut, status: 15, timedOut: true), name: f), .fail, "check.timedOut")
    expect("path direct pong + timeout", Diagnostics.path(res(directPong, timedOut: true)), .fail, "check.timedOut")
    expect("path DERP pong + timeout", Diagnostics.path(res(derpPong, status: 1, timedOut: true)), .fail, "check.timedOut")
    expect("tsmp pong + timeout", Diagnostics.tsmp(res(tsmpPong, timedOut: true)), .fail, "check.timedOut")
    expect("tsmp pong + incomplete output", Diagnostics.tsmp(res(tsmpPong, status: 0, err: "\noutput incomplete: a leftover process kept the output open", timedOut: true)), .fail, "check.timedOut")
    // Truncated output.
    expect("dig answer + truncated", Diagnostics.magicDirect(res(digOut, truncated: true), name: f), .fail, "check.commandFailed")
    expect("path direct pong + truncated", Diagnostics.path(res(directPong, truncated: true)), .fail, "check.commandFailed")
    expect("tsmp pong + truncated", Diagnostics.tsmp(res(tsmpPong, truncated: true)), .fail, "check.commandFailed")
    // tailscale ping exits 1 after a DERP-only pong ("direct connection not established"): still Info, never Passed.
    expect("path DERP pong + exit 1", Diagnostics.path(res(derpPong, status: 1, err: "direct connection not established")), .info)
    expect("path DERP pong + exit 0", Diagnostics.path(res(derpPong)), .info)
    // The CLI's own negative answer vs. a failed command.
    expect("path no reply", Diagnostics.path(res("ping \"100.64.1.9\" timed out\n", status: 1, err: "no reply")), .fail, "check.noPong")
    expect("path other error", Diagnostics.path(res("", status: 1, err: "failed to connect to local tailscaled")), .fail, "check.commandFailed")
    expect("tsmp no reply", Diagnostics.tsmp(res("", status: 1, err: "no reply")), .fail, "check.noPong")
    expect("tsmp unsafe binary", Diagnostics.tsmp(res("", status: -1, err: "x: missing or unsafe permissions")), .fail, "check.commandFailed")
}

section("publiczny IPv4/IPv6: tekst wyniku")
do {
    func core(_ v: Verdict, _ reason: InconclusiveReason? = nil, _ d: String = "") -> CheckResult {
        CheckResult(name: "Publiczny IPv6", verdict: v, detail: d, reason: reason)
    }
    let pass = Diagnostics.present(core(.pass, nil, "przez Mullvad (se-got-wg-001)"), family: "IPv6")
    check(pass.verdict == .pass && pass.name == L("check.public", "IPv6") && pass.detail.contains("(se-got-wg-001)"), "passed: \(pass.detail)")
    let fam = Diagnostics.present(core(.inconclusive, .family), family: "IPv6")
    check(fam.verdict == .inconclusive && fam.detail == L("check.otherVersion", "IPv6", "IPv6"), "other IP version explained")
    let resp = Diagnostics.present(core(.inconclusive, .response), family: "IPv6")
    check(resp.verdict == .inconclusive && resp.detail == L("check.unrecognized"), "bad response explained")
    let none = Diagnostics.present(core(.unavailable), family: "IPv6")
    check(none.verdict == .unavailable && none.detail == L("check.noConnectivity", "IPv6", "IPv6"), "no connection explained")
    check(Verdict.inconclusive.color != Verdict.pass.color && Verdict.unavailable.color != Verdict.pass.color, "inconclusive and unavailable never look passed")

    // End to end through Core: the historical case is never shown as passed.
    let hist = Parsers.mullvadCheck(curl: ProcResult(status: 0, out: #"{"ip":"203.0.113.7","mullvad_exit_ip":true}"# + "\n" + PublicIPCheck.marker + "200 ::ffff:45.83.223.233", err: ""), family: "IPv6")
    check(Diagnostics.present(hist, family: "IPv6").verdict == .inconclusive, "::ffff:IPv4 shown as inconclusive")
}

section("O programie: wersja, kanał, build")
do {
    // Real strings table, so the formatted values are compared, not just the keys.
    stringsTableOverride = NSDictionary(contentsOfFile: "src/App/Resources/en.lproj/Localizable.strings") as? [String: String]
    defer { stringsTableOverride = nil }
    check(stringsTableOverride?["about.commit"] != nil, "strings table loaded for About tests")
    let adhoc = "Ad-hoc signature. No Developer ID, not notarized."
    let full: [String: Any] = ["CFBundleShortVersionString": "1.1.0", "CFBundleVersion": "2", "TBChannel": "Experimental",
                               "TBGitCommit": "ce901d0e93e71c05e5116f83e6fb4a850adfcc45", "TBGitDirty": false, "TBSigning": "ad-hoc"]
    let a = aboutInfo(full)
    check(a == AboutInfo(version: "1.1.0 Experimental", build: "2", credits: "Commit ce901d0e93e7\n" + adhoc), "About, clean build: \(a)")

    var dirty = full; dirty["TBGitDirty"] = true
    check(aboutInfo(dirty).credits == "Commit ce901d0e93e7 with uncommitted changes\n" + adhoc, "About, uncommitted changes: \(aboutInfo(dirty).credits)")
    var other = full; other["CFBundleShortVersionString"] = "2.0.1"; other["CFBundleVersion"] = "17"; other["TBChannel"] = "Beta"
    other["TBGitCommit"] = "0123456789abcdef0123456789abcdef01234567"
    check(aboutInfo(other) == AboutInfo(version: "2.0.1 Beta", build: "17", credits: "Commit 0123456789ab\n" + adhoc), "About follows Info.plist values: \(aboutInfo(other))")

    var signed = full; signed["TBSigning"] = "developer-id"
    check(aboutInfo(signed).credits == "Commit ce901d0e93e7", "no ad-hoc line for another signing: \(aboutInfo(signed).credits)")
    var unsigned = full; unsigned["TBSigning"] = nil
    check(aboutInfo(unsigned).credits == "Commit ce901d0e93e7", "no signing claim without TBSigning")
    var noChannel = full; noChannel["TBChannel"] = nil
    check(aboutInfo(noChannel).version == "1.1.0", "without a channel the plain version")
    var noCommit = full; noCommit["TBGitCommit"] = "unknown"
    check(aboutInfo(noCommit).credits == "Commit unknown\n" + adhoc, "unknown commit stated: \(aboutInfo(noCommit).credits)")
    check(aboutInfo([:]) == AboutInfo(version: "unknown", build: "unknown", credits: "Commit unknown"), "empty Info.plist: \(aboutInfo([:]))")
    check(!aboutInfo(full).credits.lowercased().contains("copyright") && !aboutInfo(full).version.contains("©"), "no copyright text in About values")
}

section("lokalizacja")
do {
    let path = "src/App/Resources/en.lproj/Localizable.strings"
    let table = NSDictionary(contentsOfFile: path) as? [String: String] ?? [:]
    check(!table.isEmpty, "strings file parses")
    var source = ""
    for f in (try? FileManager.default.contentsOfDirectory(atPath: "src/App")) ?? [] where f.hasSuffix(".swift") {
        source += (try? String(contentsOfFile: "src/App/" + f, encoding: .utf8)) ?? ""
    }
    func specifiers(_ v: String) -> [String] {
        let re = try! NSRegularExpression(pattern: #"%(?:%|@|ld)|%[^ %@l]"#)
        return re.matches(in: v, range: NSRange(v.startIndex..., in: v)).map { String(v[Range($0.range, in: v)!]) }
    }
    for (k, v) in table {
        for sp in specifiers(v) { check(sp == "%@" || sp == "%ld" || sp == "%%", "\(k): unsupported specifier \(sp)") }
        check(source.contains("\"\(k)\""), "unused key \(k)")
    }

    // Each L("key", args…) call: key exists and the argument count matches the specifiers.
    var calls = 0
    let chars = Array(source.unicodeScalars)
    var i = 0
    while i + 3 < chars.count {
        guard chars[i] == "L", chars[i + 1] == "(", chars[i + 2] == "\"", i == 0 || !CharacterSet.alphanumerics.contains(chars[i - 1]) else { i += 1; continue }
        var j = i + 3, key = ""
        while j < chars.count, chars[j] != "\"" { key.unicodeScalars.append(chars[j]); j += 1 }
        // Count top-level commas until the matching ')', skipping string literals.
        var depth = 1, args = 0, inString = false, k = j + 1
        while k < chars.count, depth > 0 {
            let c = chars[k]
            if inString { if c == "\\" { k += 1 } else if c == "\"" { inString = false } }
            else if c == "\"" { inString = true }
            else if c == "(" || c == "[" { depth += 1 }
            else if c == ")" || c == "]" { depth -= 1 }
            else if c == ",", depth == 1 { args += 1 }
            k += 1
        }
        calls += 1
        if let v = table[key] {
            let n = specifiers(v).filter { $0 != "%%" }.count
            check(n == args, "L(\"\(key)\"): \(args) argument(s), format has \(n)")
        } else {
            check(false, "missing key \(key)")
        }
        i = k
    }
    check(calls > 100, "found L() calls: \(calls)")
    for key in ["test.leakFound", "test.notActive", "test.pickDevice", "test.someFailed", "test.someInconclusive"] { check(table[key] != nil, "notice key \(key)") }

    // No connection, a bad response and another IP version never read as protection.
    for key in ["check.noConnectivity", "check.unrecognized", "check.otherVersion", "test.someInconclusive"] {
        let v = table[key] ?? ""
        check(v.contains("n’t show") && !v.lowercased().contains("protected.") && !v.contains("secure"), "\(key) claims nothing: \(v)")
    }

    // Daybreak #1: the green status claims no routing it does not observe; the attention texts name the cause.
    let on = table["status.on.detail"] ?? ""
    check(on.contains("Mullvad reports it’s connected") && !on.contains("still goes through Mullvad") && !on.contains("are reachable while"),
          "On detail is scoped to what was observed: \(on)")
    check((table["status.onNoMullvad.detail"] ?? "").contains("can’t confirm") && (table["status.onNoMullvad.detail"] ?? "").contains("Disable"),
          "Mullvad-not-connected text: no confirmation claimed, Disable offered")
    check((table["status.onNoTailscale.detail"] ?? "").contains("may not be reachable"), "Tailscale-not-running text")
    check((table["check.commandFailed"] ?? "").contains("isn’t counted as passed"), "failed command is not a pass")
    check((table["admin.uninstalledLeftovers"] ?? "").contains("left in place"), "uninstall with leftovers says so")

    // Wording that matters: unreadable PF is not "off", and the DNS warning is about a possible conflict.
    let unreadable = table["status.off.pfUnreadable"] ?? ""
    check(unreadable.hasPrefix("TailBridge can’t read the firewall state"), "unreadable PF message: \(unreadable)")
    check(!unreadable.contains("turned off") && unreadable.contains("doesn’t mean the firewall is off"), "unreadable PF is not presented as off")
    check(unreadable.contains("Refresh") && unreadable.contains("Install Helper"), "unreadable PF gives a next step")
    check((table["tech.pfUnreadable"] ?? "").contains("can’t read"), "technical row says unreadable")
    let dns = table["mullvad.dnsFilterWarning"] ?? ""
    check(dns.contains("may conflict") && dns.contains("may stop") && !dns.contains("will "), "DNS warning speaks of a possible conflict: \(dns)")
    check(dns.contains("doesn’t change these settings"), "DNS warning: TailBridge changes nothing")
}

print("\nWynik: \(passes) OK, \(failures) BŁĘDÓW")
exit(failures == 0 ? 0 : 1)
