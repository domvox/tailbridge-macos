import Foundation

struct IfAddr: Equatable {
    var name: String
    var index: UInt32
    var family: Int32      // AF_INET or AF_INET6
    var address: String    // canonical text form
    var up: Bool           // IFF_UP && IFF_RUNNING
}

/// Identity of the Tailscale interface at the moment the exception was installed.
struct Identity: Codable, Equatable {
    var iface: String
    var index: UInt32
    var ip4: String
    var ip6: String
    var domain: String

    var fieldsValid: Bool {
        Validate.utun(iface) && index > 0 && Validate.tailscaleIPv4(ip4)
            && Validate.tailscaleIPv6(ip6) && Validate.tailnetDomain(domain)
    }
}

enum Interfaces {
    static func snapshot() -> [IfAddr] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var out: [IfAddr] = []
        var cur: UnsafeMutablePointer<ifaddrs>? = first
        while let p = cur {
            defer { cur = p.pointee.ifa_next }
            guard let sa = p.pointee.ifa_addr else { continue }
            let name = String(cString: p.pointee.ifa_name)
            let flags = Int32(p.pointee.ifa_flags)
            let up = (flags & IFF_UP) != 0 && (flags & IFF_RUNNING) != 0
            let family = Int32(sa.pointee.sa_family)
            var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            if family == AF_INET {
                var a = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                guard inet_ntop(AF_INET, &a, &buf, socklen_t(buf.count)) != nil else { continue }
            } else if family == AF_INET6 {
                var a = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                guard inet_ntop(AF_INET6, &a, &buf, socklen_t(buf.count)) != nil else { continue }
            } else { continue }
            out.append(IfAddr(name: name, index: if_nametoindex(name), family: family,
                              address: String(cString: buf), up: up))
        }
        return out
    }

    /// The single interface that carries both addresses, or nil.
    static func locate(ip4: String, ip6: String, in addrs: [IfAddr]) -> (name: String, index: UInt32)? {
        let names = Set(addrs.filter { $0.address == ip4 || $0.address == ip6 }.map(\.name))
        guard names.count == 1, let n = names.first,
              addrs.contains(where: { $0.name == n && $0.address == ip4 && $0.family == AF_INET }),
              addrs.contains(where: { $0.name == n && $0.address == ip6 && $0.family == AF_INET6 }),
              let idx = addrs.first(where: { $0.name == n })?.index else { return nil }
        return (n, idx)
    }

    /// nil when the recorded identity still holds exactly; otherwise a human-readable reason.
    static func problem(_ id: Identity, in addrs: [IfAddr]) -> String? {
        guard id.fieldsValid else { return "nieprawidłowy zapisany stan" }
        let mine = addrs.filter { $0.name == id.iface }
        if mine.isEmpty { return "interfejs \(id.iface) zniknął (Tailscale zatrzymany?)" }
        if mine.contains(where: { $0.index != id.index }) { return "interfejs \(id.iface) ma nowy indeks" }
        if !mine.allSatisfy(\.up) { return "interfejs \(id.iface) nie jest UP/RUNNING" }
        let v4 = mine.filter { $0.family == AF_INET }.map(\.address)
        if v4 != [id.ip4] { return "adresy IPv4 na \(id.iface) zmieniły się" }
        let v6 = mine.filter { $0.family == AF_INET6 && !$0.address.hasPrefix("fe80:") }.map(\.address)
        if v6 != [id.ip6] { return "adresy IPv6 na \(id.iface) zmieniły się" }
        if addrs.contains(where: { $0.name != id.iface && ($0.address == id.ip4 || $0.address == id.ip6) }) {
            return "adres Tailscale występuje także na innym interfejsie"
        }
        return nil
    }

    /// utun interfaces that currently carry a Tailscale IPv4 and IPv6 address.
    static func tailscaleCandidates(_ addrs: [IfAddr]) -> Set<String> {
        let byName = Dictionary(grouping: addrs.filter { Validate.utun($0.name) }, by: \.name)
        return Set(byName.compactMap { name, list in
            let has4 = list.contains { $0.family == AF_INET && Validate.tailscaleIPv4($0.address) }
            let has6 = list.contains { $0.family == AF_INET6 && Validate.tailscaleIPv6($0.address) }
            return has4 && has6 ? name : nil
        })
    }
}
