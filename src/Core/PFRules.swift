import Foundation

enum PFRules {
    static let anchor = "com.apple/tailbridge"
    static let legacyAnchor = "com.apple/codex-vpn-coexist"
    static let ts4Range = "100.64.0.0/10"
    static let ts6Range = "fd7a:115c:a1e0::/48"

    /// Rules as loaded. Explicit `flags any` so the default `flags S/SA` cannot apply.
    static func rules(_ id: Identity) -> [String] {
        let i = id.iface
        return [
            "pass out quick on \(i) inet from \(id.ip4) to \(ts4Range) flags any no state",
            "pass in quick on \(i) inet from \(ts4Range) to \(id.ip4) flags any no state",
            "pass out quick on \(i) inet6 from \(id.ip6) to \(ts6Range) flags any no state",
            "pass in quick on \(i) inet6 from \(ts6Range) to \(id.ip6) flags any no state",
        ]
    }

    /// What `pfctl -a ... -sr` is expected to print for `rules(id)`.
    /// pfctl prints no flags token for a no-state rule whose flags are empty (`flags any`).
    /// Confirmed on a live macOS 27.2 kernel; any other output is treated as mismatch (fail closed).
    static func expectedPrinted(_ id: Identity) -> [String] {
        rules(id).map { $0.replacingOccurrences(of: " flags any no state", with: " no state") }
    }

    enum AnchorState: String, Codable { case empty, exact, mismatch }

    /// Exact set comparison (order-independent, no normalisation).
    static func classify(printed: [String], expected: [String]) -> AnchorState {
        if printed.isEmpty { return .empty }
        return printed.sorted() == expected.sorted() ? .exact : .mismatch
    }

    /// The four broad prototype rules (legacy/vpn-coexist.sh:129-132), on any single utun.
    /// Returns the utun name if recognised exactly.
    static func legacyInterface(_ printed: [String]) -> String? {
        guard printed.count == 4 else { return nil }
        let f = "( flags S/SA)? no state"
        let u = "(utun(?:0|[1-9][0-9]{0,3}))"
        let pats = [
            "pass out quick on \(u) inet from any to 100\\.64\\.0\\.0/10\(f)",
            "pass in quick on \(u) inet from 100\\.64\\.0\\.0/10 to any\(f)",
            "pass out quick on \(u) inet6 from any to fd7a:115c:a1e0::/48\(f)",
            "pass in quick on \(u) inet6 from fd7a:115c:a1e0::/48 to any\(f)",
        ]
        var ifaces = Set<String>()
        var used = Set<Int>()
        for line in printed {
            guard let k = pats.indices.first(where: { !used.contains($0) && Validate.full(line, pats[$0]) }) else { return nil }
            used.insert(k)
            guard let name = line.split(separator: " ").dropFirst(4).first else { return nil }
            ifaces.insert(String(name))
        }
        return ifaces.count == 1 ? ifaces.first : nil
    }

    /// `anchor "com.apple/*"` must be evaluated before `anchor "mullvad"` in the main ruleset.
    static func appleBeforeMullvad(_ mainRules: [String]) -> Bool {
        func idx(_ name: String) -> Int? {
            mainRules.firstIndex { line in
                let t = line.split(separator: " ")
                return t.count >= 2 && t[0] == "anchor" && t[1] == "\"\(name)\""
            }
        }
        guard let a = idx("com.apple/*"), let m = idx("mullvad") else { return false }
        return a < m
    }

    enum PFState: Equatable { case enabled, disabled, unreadable }

    /// From `pfctl -s info`. Output without a `Status:` line (for example empty output from a
    /// failed run) is a read error, never "disabled".
    static func pfState(_ info: String) -> PFState {
        for line in info.split(whereSeparator: \.isNewline) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("Status: Enabled") { return .enabled }
            if t.hasPrefix("Status: Disabled") { return .disabled }
        }
        return .unreadable
    }

    /// com.apple/* before mullvad in the main ruleset (`pfctl -sr`), or nil when it can't be read.
    /// An empty listing counts as unreadable: with Mullvad connected the main ruleset is never empty.
    static func mainOrder(_ main: ProcResult) -> Bool? {
        guard main.ok, !main.lines.isEmpty else { return nil }
        return appleBeforeMullvad(main.lines)
    }
}
