import AppKit

// Maps a read-only Snapshot to what the window shows. No side effects.

/// How a value should read: icon and color always go together with text.
enum Tone {
    case ok, warning, error, neutral, info, unknown

    var symbol: String {
        switch self {
        case .ok: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        case .neutral: return "minus.circle"
        case .info: return "info.circle"
        case .unknown: return "questionmark.circle"
        }
    }
    var color: NSColor {
        switch self {
        case .ok: return .systemGreen
        case .warning: return .systemOrange
        case .error: return .systemRed
        case .neutral, .info, .unknown: return .secondaryLabelColor
        }
    }
    var label: String {
        switch self {
        case .ok: return L("tone.ok")
        case .warning: return L("tone.warning")
        case .error: return L("tone.error")
        case .neutral: return L("tone.neutral")
        case .info: return L("tone.info")
        case .unknown: return L("tone.unknown")
        }
    }
}

enum Overall { case checking, off, active, attention, error }
enum PrimaryAction { case enable, disable }

struct Headline {
    var state: Overall
    var title: String
    var detail: String
    var action: PrimaryAction
    var actionEnabled: Bool
    /// Show a secondary Disable button next to a primary Enable, to remove leftovers.
    var offersCleanup = false
    /// Enable may be requested (button and menu): only when it is the offered, clickable action.
    var canEnable: Bool { action == .enable && actionEnabled }

    var symbol: String {
        switch state {
        case .checking: return "ellipsis.circle"
        case .off: return "power.circle"
        case .active: return "checkmark.shield.fill"
        case .attention: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }
    var color: NSColor {
        switch state {
        case .checking, .off: return .secondaryLabelColor
        case .active: return .systemGreen
        case .attention: return .systemOrange
        case .error: return .systemRed
        }
    }
}

struct StatusLine {
    var tone: Tone
    var value: String
    var secondary: String?
    var help: String?
}

struct DetailRow {
    var label: String
    var value: String
    var tone: Tone
}

extension Verdict {
    var label: String {
        switch self {
        case .pass: return L("verdict.pass")
        case .fail: return L("verdict.fail")
        case .leak: return L("verdict.leak")
        case .unavailable: return L("verdict.unavailable")
        case .notVerified: return L("verdict.notTested")
        case .info: return L("verdict.info")
        case .inconclusive: return L("verdict.inconclusive")
        }
    }
    var symbol: String {
        switch self {
        case .pass: return "checkmark.circle.fill"
        case .fail: return "xmark.circle.fill"
        case .leak: return "exclamationmark.triangle.fill"
        case .unavailable: return "slash.circle"
        case .notVerified: return "circle.dashed"
        case .info: return "info.circle"
        case .inconclusive: return "questionmark.circle"
        }
    }
    var color: NSColor {
        switch self {
        case .pass: return .systemGreen
        case .fail, .leak: return .systemRed
        case .unavailable, .inconclusive: return .systemOrange
        case .notVerified, .info: return .secondaryLabelColor
        }
    }
}

/// Core reports some file problems in Polish; show them in the UI language.
func foreignReason(_ w: String) -> String {
    let known = ["nieoczekiwany właściciel": "foreign.owner", "nieczytelny": "foreign.unreadable",
                 "nierozpoznana treść — może zawierać Twoje ustawienia": "foreign.unknownUser",
                 "nierozpoznana treść": "foreign.unknown", "nie jest zwykłym plikiem": "foreign.notFile"]
    return known[w].map { L($0) } ?? w
}

extension Snapshot {
    var tailscaleRunning: Bool { ts?.backendState == "Running" }

    var headline: Headline {
        guard taken else {
            return Headline(state: .checking, title: L("status.checking.title"), detail: L("status.checking.detail"),
                            action: .enable, actionEnabled: false)
        }
        if workaroundActive {
            // The helper's observation covers only TailBridge's own exception. Green "On" also needs
            // Mullvad and Tailscale connected right now; unreadable Mullvad status counts as not connected.
            if !mullvadConnected {
                return Headline(state: .attention, title: L("status.stale.title"), detail: L("status.onNoMullvad.detail"),
                                action: .disable, actionEnabled: true)
            }
            if !tailscaleRunning {
                return Headline(state: .attention, title: L("status.stale.title"), detail: L("status.onNoTailscale.detail"),
                                action: .disable, actionEnabled: true)
            }
            return Headline(state: .active, title: L("status.on.title"), detail: L("status.on.detail"),
                            action: .disable, actionEnabled: true)
        }
        if monitorFresh, let st = status {
            if st.cleanupPending || st.anchor == "mismatch" || st.anchor == "error" {
                return Headline(state: .error, title: L("status.error.title"), detail: L("status.error.detail"),
                                action: .disable, actionEnabled: true)
            }
            if st.identity != nil {
                return Headline(state: .attention, title: L("status.stale.title"), detail: L("status.stale.detail"),
                                action: .disable, actionEnabled: true)
            }
        }
        if !helperInstalled {
            // Without the helper only the Tailscale setting file can be cleaned up (Disable removes it).
            let leftovers = env == .ours || env == .legacy || resolverLeftover
            return Headline(state: .attention, title: L("status.setup.title"),
                            detail: L("status.setup.detail") + (leftovers ? " " + L("status.leftovers") : ""),
                            action: .enable, actionEnabled: false, offersCleanup: leftovers)
        }
        if !monitorFresh {
            // The exception may still be in place; Disable works without the monitor.
            return Headline(state: .attention, title: L("status.unknown.title"), detail: L("status.unknown.detail"),
                            action: .disable, actionEnabled: true)
        }
        let blocker = enableBlocker
        let leftovers = resolverLeftover || legacyLeftover
        return Headline(state: .off, title: L("status.off.title"),
                        detail: (blocker ?? L("status.off.ready")) + (leftovers ? " " + L("status.leftovers") : ""),
                        action: .enable, actionEnabled: blocker == nil, offersCleanup: leftovers)
    }

    /// Why Enable would be refused right now, or nil. Mirrors the checks in `enable()` and the
    /// helper's PF preconditions, in the helper's order: Engine refuses when PF is off or its state
    /// can't be read, then when com.apple/* isn't before mullvad or the main rules can't be read.
    var enableBlocker: String? {
        if !mullvadConnected { return L("status.off.needMullvad") }
        guard let t = ts, t.backendState == "Running", t.ip4 != nil, t.ip6 != nil, iface != nil else {
            return L("status.off.needTailscale")
        }
        if t.domain == nil { return L("status.off.needDomain") }
        if let st = status {
            switch st.pfEnabled {
            case nil: return L("status.off.pfUnreadable")
            case false?: return L("status.off.needPF")
            default: break
            }
            switch st.appleBeforeMullvad {
            case nil: return L("status.off.pfUnreadable")
            case false?: return L("status.off.needOrder")
            default: break
            }
        }
        return nil
    }

    /// Mullvad's content blockers use a DNS server in 100.64.0.0/10, the range Tailscale routes.
    /// Only a warning: it may or may not break lookups, and TailBridge never changes the setting.
    var dnsFilterWarning: String? {
        guard taken, mullvadConnected, let b = mullvadDNSBlockers, !b.isEmpty else { return nil }
        return L("mullvad.dnsFilterWarning", b.joined(separator: ", "))
    }

    /// TailBridge's resolver file while TailBridge is off.
    var resolverLeftover: Bool { resolver == .some(.ours) || resolver == .some(.legacy) }
    /// Prototype rules that Disable also removes.
    var legacyLeftover: Bool {
        guard monitorFresh, let st = status else { return false }
        return st.legacyAnchor == "recognized" || st.legacyAnchor == "unknown"
    }

    /// Section messages go out of date when this changes.
    var headerContext: String { let h = headline; return "\(h.title)|\(h.detail)|\(h.action)|\(h.actionEnabled)" }
    var adminContext: String { "\(helperInstalled)|\(monitorFresh)" }

    /// "Block traffic when the VPN is disconnected: off" → on/off text.
    var lockdownText: String? {
        guard let l = lockdown?.lowercased() else { return nil }
        if l.hasSuffix(": on") || l.hasSuffix(" on") { return L("mullvad.lockdownOn") }
        if l.hasSuffix(": off") || l.hasSuffix(" off") { return L("mullvad.lockdownOff") }
        return nil
    }

    var mullvadLine: StatusLine {
        guard taken else { return StatusLine(tone: .unknown, value: L("common.checking")) }
        if mullvadError != nil {
            return StatusLine(tone: .warning, value: L("mullvad.unavailable"), secondary: L("mullvad.unavailableHint"))
        }
        let help = L("mullvad.lockdownHelp")
        switch mullvadState {
        case "Connected": return StatusLine(tone: .ok, value: L("mullvad.connected"), secondary: lockdownText, help: help)
        case "Disconnected": return StatusLine(tone: .warning, value: L("mullvad.disconnected"), secondary: lockdownText, help: help)
        case "Connecting": return StatusLine(tone: .warning, value: L("mullvad.connecting"), secondary: lockdownText, help: help)
        default:
            let blocked = mullvadState.hasPrefix("Blocked")
            return StatusLine(tone: .warning, value: blocked ? L("mullvad.blocked") : mullvadState,
                              secondary: lockdownText, help: mullvadState)
        }
    }

    var tailscaleLine: StatusLine {
        guard taken else { return StatusLine(tone: .unknown, value: L("common.checking")) }
        guard let t = ts else {
            return StatusLine(tone: .warning, value: L("tailscale.unavailable"), secondary: L("tailscale.unavailableHint"))
        }
        switch t.backendState {
        case "Running":
            guard iface != nil else {
                return StatusLine(tone: .warning, value: L("tailscale.connected"), secondary: L("tailscale.noInterface"))
            }
            let parts = [t.ip4, t.domain].compactMap { $0 }
            return StatusLine(tone: .ok, value: L("tailscale.connected"), secondary: parts.joined(separator: " · "))
        case "NeedsLogin": return StatusLine(tone: .warning, value: L("tailscale.signedOut"), secondary: L("tailscale.signInHint"))
        case "NeedsMachineAuth": return StatusLine(tone: .warning, value: L("tailscale.needsApproval"))
        case "Stopped": return StatusLine(tone: .warning, value: L("tailscale.stopped"), secondary: L("tailscale.startHint"))
        case "Starting": return StatusLine(tone: .unknown, value: L("tailscale.starting"))
        default: return StatusLine(tone: .warning, value: t.backendState)
        }
    }

    var technicalRows: [DetailRow] {
        var rows: [DetailRow] = []
        let unknownMonitor = L("tech.needsMonitor")

        rows.append(DetailRow(label: L("tech.interface"),
                              value: iface.map { L("tech.interfaceValue", $0.name, Int($0.index)) } ?? L("tech.interfaceMissing"),
                              tone: iface == nil ? .warning : .info))
        let addrs = [ts?.ip4, ts?.ip6].compactMap { $0 }
        rows.append(DetailRow(label: L("tech.addresses"), value: addrs.isEmpty ? "—" : addrs.joined(separator: "  "), tone: .info))

        if !helperInstalled { rows.append(DetailRow(label: L("tech.helper"), value: L("tech.helperMissing"), tone: .neutral)) }
        else if monitorFresh { rows.append(DetailRow(label: L("tech.helper"), value: L("tech.helperRunning", Int(statusAge ?? 0)), tone: .ok)) }
        else { rows.append(DetailRow(label: L("tech.helper"), value: L("tech.helperStale"), tone: .warning)) }

        if let st = status, monitorFresh {
            var value: String, tone: Tone
            switch st.anchor {
            case "exact": value = L("tech.pfExact", st.identity?.iface ?? "?"); tone = .ok
            case "empty": value = L("tech.pfEmpty"); tone = .neutral
            case "mismatch": value = L("tech.pfMismatch"); tone = .error
            case "error": value = L("tech.pfError"); tone = .error
            default: value = st.anchor; tone = .warning
            }
            // PF off makes any rules inert and blocks Enable; it is reported before rule order (as the helper checks it first).
            // Unreadable is not "off". The anchor is read separately, so its state stays visible.
            let unreadable = st.pfEnabled == nil || (st.pfEnabled == true && st.appleBeforeMullvad == nil)
            if unreadable { value += " · " + L("tech.pfUnreadable"); if tone != .error { tone = .warning } }
            else if st.pfEnabled == false { value += " · " + L("tech.pfOff"); if tone != .error { tone = .warning } }
            else if st.appleBeforeMullvad == false { value += " · " + L("tech.pfOrder"); tone = .error }
            rows.append(DetailRow(label: L("tech.pf"), value: value, tone: tone))
        } else { rows.append(DetailRow(label: L("tech.pf"), value: unknownMonitor, tone: .unknown)) }

        switch resolver {
        case .some(.ours): rows.append(DetailRow(label: L("tech.resolver"), value: L("tech.resolverOurs"), tone: .ok))
        case .some(.legacy): rows.append(DetailRow(label: L("tech.resolver"), value: L("tech.resolverLegacy"), tone: .neutral))
        case .some(.absent): rows.append(DetailRow(label: L("tech.resolver"), value: L("tech.none"), tone: .neutral))
        case .some(.foreign(let w)): rows.append(DetailRow(label: L("tech.resolver"), value: L("tech.foreignFile", foreignReason(w)), tone: .warning))
        case .none: rows.append(DetailRow(label: L("tech.resolver"), value: L("tech.resolverNoDomain"), tone: .unknown))
        }

        switch env {
        case .ours: rows.append(DetailRow(label: L("tech.env"), value: L("tech.envOurs"), tone: .ok))
        case .legacy: rows.append(DetailRow(label: L("tech.env"), value: L("tech.envLegacy"), tone: .neutral))
        case .absent: rows.append(DetailRow(label: L("tech.env"), value: L("tech.none"), tone: .neutral))
        case .foreign(let w): rows.append(DetailRow(label: L("tech.env"), value: L("tech.foreignFile", foreignReason(w)), tone: .warning))
        }

        if let st = status, monitorFresh {
            if st.legacyAnchor == "empty" && st.legacyState == "absent" {
                rows.append(DetailRow(label: L("tech.legacy"), value: L("tech.legacyNone"), tone: .ok))
            } else {
                rows.append(DetailRow(label: L("tech.legacy"), value: L("tech.legacyValue", st.legacyAnchor, st.legacyState),
                                      tone: st.legacyAnchor == "empty" ? .neutral : .warning))
            }
        } else { rows.append(DetailRow(label: L("tech.legacy"), value: unknownMonitor, tone: .unknown)) }
        return rows
    }
}

// MARK: Section messages

enum NoticeKind: Int, Comparable {
    case success, info, warning, error
    static func < (a: NoticeKind, b: NoticeKind) -> Bool { a.rawValue < b.rawValue }
}

/// What a section message shows, and the window state it was written for.
struct NoticeState: Equatable {
    var kind: NoticeKind
    var message: String
    /// Set at the first idle refresh after the message appears; nil until then.
    var context: String?

    init(_ kind: NoticeKind, _ message: String) { self.kind = kind; self.message = message }

    /// A follow-up is appended and never downgrades an earlier, more serious message.
    func adding(_ k: NoticeKind, _ m: String) -> NoticeState {
        NoticeState(max(kind, k), message + "\n" + m)
    }

    /// nil when the window state has changed since the message was written. While an action
    /// runs (`idle == false`) intermediate states are ignored.
    func refreshed(context now: String, idle: Bool) -> NoticeState? {
        guard idle else { return self }
        guard let c = context else { var n = self; n.context = now; return n }
        return c == now ? self : nil
    }
}

// MARK: Connection Test

/// The fields a test ran with, normalized the same way the test reads them.
func testTarget(ip: String, name: String, port: String) -> String {
    let t = { (s: String) in s.trimmingCharacters(in: .whitespaces) }
    return "\(t(ip))|\(t(name).lowercased())|\(t(port))"
}

/// Index of the device matching the IP and (if given) the name, case-insensitively.
func matchingPeer(ip: String, name: String, in peers: [Peer]) -> Int? {
    let ip = ip.trimmingCharacters(in: .whitespaces)
    let name = name.trimmingCharacters(in: .whitespaces).lowercased()
    guard !ip.isEmpty else { return nil }
    return peers.firstIndex { $0.ip4 == ip && (name.isEmpty || $0.name.lowercased() == name) }
}

struct TestRun: Equatable {
    var target: String
    var context: String
}

enum ResultsFreshness: Equatable { case current, targetChanged, stateChanged }

func freshness(of run: TestRun, target: String, context: String) -> ResultsFreshness {
    if run.target != target { return .targetChanged }
    if run.context != context { return .stateChanged }
    return .current
}

struct ResultSummary: Equatable {
    var passed: Int, failed: Int, notTested: Int
    var inconclusive = 0
    /// Most important next step: leak, then inactive workaround, then no device, then failures,
    /// then inconclusive results.
    var notice: NoticeKind?
    var noticeKey: String?
}

func summarize(_ results: [CheckResult], workaroundActive: Bool, hadPeer: Bool) -> ResultSummary {
    let count = { (v: [Verdict]) in results.filter { v.contains($0.verdict) }.count }
    var s = ResultSummary(passed: count([.pass]), failed: count([.fail, .leak]), notTested: count([.notVerified, .unavailable]),
                          inconclusive: count([.inconclusive]))
    if results.contains(where: { $0.verdict == .leak }) { (s.notice, s.noticeKey) = (.error, "test.leakFound") }
    else if !workaroundActive { (s.notice, s.noticeKey) = (.warning, "test.notActive") }
    else if !hadPeer { (s.notice, s.noticeKey) = (.info, "test.pickDevice") }
    else if s.failed > 0 { (s.notice, s.noticeKey) = (.warning, "test.someFailed") }
    else if s.inconclusive > 0 { (s.notice, s.noticeKey) = (.warning, "test.someInconclusive") }
    return s
}

/// What the Connection Test has to show: nothing yet, a run in progress, out-of-date or current results.
enum TestOutcome: Equatable {
    case none, running
    /// Results from `at` no longer describe the current device or TailBridge state.
    case stale(at: String)
    case results(ResultSummary, at: String)
}

/// One line shown under the Connection Test heading while the section is collapsed.
/// Green only when every counted check passed and nothing needs attention; never for no, running or stale results.
/// `help` is the status in words for the icon and VoiceOver: "Passed" for checks, never a generic "OK" that could read as "safe".
func collapsedTestLine(_ o: TestOutcome) -> StatusLine {
    switch o {
    case .none: return StatusLine(tone: .unknown, value: L("test.none"), help: L("verdict.notTested"))
    case .running: return StatusLine(tone: .unknown, value: L("test.running"), help: Tone.unknown.label)
    case .stale(let at): return StatusLine(tone: .warning, value: L("test.collapsedStale", at), help: Tone.warning.label)
    case .results(let s, let at):
        let text = L("test.summary", s.passed, s.failed, s.inconclusive, s.notTested, at)
        // Priority: failure or leak, then inconclusive or any notice (inactive workaround, no device…),
        // then coverage only. Checks that weren't run are not a problem, but never green either.
        if s.failed > 0 || s.notice == .error { return StatusLine(tone: .error, value: text, help: Tone.error.label) }
        if s.inconclusive > 0 || s.notice != nil { return StatusLine(tone: .warning, value: text, help: Tone.warning.label) }
        if s.passed == 0 { return StatusLine(tone: .info, value: text, help: L("verdict.notTested")) }
        if s.notTested > 0 { return StatusLine(tone: .info, value: text, help: L("test.partial")) }
        return StatusLine(tone: .ok, value: text, help: L("verdict.pass"))
    }
}

// MARK: About panel

/// What the standard About panel shows besides the name and icon. Reads only Info.plist values written by build.sh.
/// The channel goes next to the version, commit and signature into the credits; the copyright field is not used for them.
struct AboutInfo: Equatable {
    var version: String   // "1.1.0 Experimental"; the panel adds the build number in parentheses
    var build: String
    var credits: String
}

func aboutInfo(_ info: [String: Any]) -> AboutInfo {
    func text(_ key: String) -> String { ((info[key] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    let version = text("CFBundleShortVersionString"), build = text("CFBundleVersion"), channel = text("TBChannel")
    let commit = text("TBGitCommit")
    var lines: [String] = []
    if commit.isEmpty || commit == "unknown" {
        lines.append(L("about.commit", L("about.unknown")))
    } else {
        let short = String(commit.prefix(12))
        lines.append(info["TBGitDirty"] as? Bool == true ? L("about.commitModified", short) : L("about.commit", short))
    }
    if text("TBSigning") == "ad-hoc" { lines.append(L("about.adhoc")) }
    return AboutInfo(version: channel.isEmpty ? (version.isEmpty ? L("about.unknown") : version) : L("about.version", version, channel),
                     build: build.isEmpty ? L("about.unknown") : build,
                     credits: lines.joined(separator: "\n"))
}
