import Foundation

/// Strict validators for every value that crosses a privilege or process boundary.
enum Validate {
    private static func ascii(_ s: String) -> Bool { s.unicodeScalars.allSatisfy { $0.isASCII } }

    static func full(_ s: String, _ pattern: String) -> Bool {
        // `$` would also match before a trailing "\n"; require the match to span the whole string.
        guard ascii(s), let re = try? NSRegularExpression(pattern: "^(?:" + pattern + ")\\z") else { return false }
        let all = NSRange(location: 0, length: s.utf16.count)
        return re.firstMatch(in: s, range: all)?.range == all
    }

    static func ipv4Octets(_ s: String) -> [UInt8]? {
        guard full(s, "(0|[1-9][0-9]{0,2})(\\.(0|[1-9][0-9]{0,2})){3}") else { return nil }
        let parts = s.split(separator: ".").compactMap { UInt8($0) }
        return parts.count == 4 ? parts : nil
    }

    /// Own Tailscale IPv4: 100.64.0.0/10, never the 100.100.100.100 service address.
    static func tailscaleIPv4(_ s: String) -> Bool {
        guard let b = ipv4Octets(s), b[0] == 100, (64...127).contains(b[1]) else { return false }
        return s != "100.100.100.100"
    }

    static func ipv6Bytes(_ s: String) -> [UInt8]? {
        guard !s.isEmpty, s.count <= 39, full(s, "[0-9a-f:]+") else { return nil }
        var a = in6_addr()
        guard inet_pton(AF_INET6, s, &a) == 1 else { return nil }
        return withUnsafeBytes(of: &a) { Array($0) }
    }

    static func canonicalIPv6(_ bytes: [UInt8]) -> String? {
        guard bytes.count == 16 else { return nil }
        var a = in6_addr()
        withUnsafeMutableBytes(of: &a) { $0.copyBytes(from: bytes) }
        var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &a, &buf, socklen_t(buf.count)) != nil else { return nil }
        return String(cString: buf)
    }

    static let tsULAPrefix: [UInt8] = [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0]

    /// Own Tailscale IPv6 inside fd7a:115c:a1e0::/48, in canonical (pfctl-printed) form.
    static func tailscaleIPv6(_ s: String) -> Bool {
        guard let b = ipv6Bytes(s), Array(b.prefix(6)) == tsULAPrefix else { return false }
        return canonicalIPv6(b) == s
    }

    static func utun(_ s: String) -> Bool { full(s, "utun(0|[1-9][0-9]{0,3})") }

    static func tailnetDomain(_ s: String) -> Bool { full(s, "[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.ts\\.net") }

    static func hostLabel(_ s: String) -> Bool { full(s, "[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?") }

    static func port(_ s: String) -> UInt16? {
        guard full(s, "[1-9][0-9]{0,4}"), let p = UInt16(s) else { return nil }
        return p
    }

    /// True when an address string (v4 or v6) belongs to Tailscale ranges.
    static func isTailscaleAddress(_ s: String) -> Bool {
        if let b = ipv4Octets(s) { return b[0] == 100 && (64...127).contains(b[1]) }
        if let b = ipv6Bytes(s.lowercased()) { return Array(b.prefix(6)) == tsULAPrefix }
        return false
    }
}
