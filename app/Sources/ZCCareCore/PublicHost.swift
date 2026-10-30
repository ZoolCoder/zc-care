import Darwin
import Foundation

/// Whether a host is on the internet rather than this Mac or its local
/// network. Addresses are read the way the system reads them, so 127.1,
/// 0x7f.1, 2130706433 and [::ffff:127.0.0.1] all count as loopback.
public enum PublicHost {
    /// The host's own text: a name, or an address in any form the system
    /// accepts. A name is public unless it is a local one; `resolves`
    /// checks where it points.
    public static func named(_ host: String) -> Bool {
        let host = bare(host)
        guard !host.isEmpty, host != "localhost",
              ![".local", ".localhost", ".internal", ".lan", ".home.arpa"].contains(where: host.hasSuffix) else { return false }
        if let addresses = addresses(host, numeric: true) { return addresses.allSatisfy(isPublic) }
        return true
    }

    /// Looks the name up: public when every address it has is. A name that
    /// does not resolve passes, since the connection then fails anyway.
    public static func resolves(_ host: String) -> Bool {
        let host = bare(host)
        guard named(host) else { return false }
        return (addresses(host, numeric: false) ?? []).allSatisfy(isPublic)
    }

    /// Lowercased, without IPv6 brackets or the root's trailing dot.
    static func bare(_ host: String) -> String {
        var host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host.hasSuffix(".") { host.removeLast() }
        return host
    }

    /// The addresses getaddrinfo gives, as raw bytes: 4 for IPv4, 16 for
    /// IPv6. Nil when the lookup fails, or, for numeric, when it is a name.
    static func addresses(_ host: String, numeric: Bool) -> [[UInt8]]? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        if numeric { hints.ai_flags = AI_NUMERICHOST }
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &list) == 0, let first = list else { return nil }
        defer { freeaddrinfo(first) }
        var out: [[UInt8]] = []
        for info in sequence(first: first, next: { $0.pointee.ai_next }) {
            guard let addr = info.pointee.ai_addr else { continue }
            switch Int32(addr.pointee.sa_family) {
            case AF_INET:
                addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    var a = $0.pointee.sin_addr
                    out.append(withUnsafeBytes(of: &a) { Array($0) })
                }
            case AF_INET6:
                addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                    var a = $0.pointee.sin6_addr
                    out.append(withUnsafeBytes(of: &a) { Array($0) })
                }
            default: continue
            }
        }
        return out
    }

    /// Network-order bytes of an IPv4 or IPv6 address.
    static func isPublic(_ b: [UInt8]) -> Bool {
        if b.count == 4 {
            switch (b[0], b[1]) {
            case (0, _), (10, _), (127, _), (169, 254), (192, 168), (172, 16...31), (100, 64...127): return false
            case (224...255, _): return false
            default: return true
            }
        }
        guard b.count == 16 else { return false }
        let head = Array(b[0..<12])
        // An IPv4 address inside IPv6: mapped, compatible or NAT64.
        if head == Array(repeating: 0, count: 10) + [0xff, 0xff] || head == Array(repeating: 0, count: 12)
            || head == [0x00, 0x64, 0xff, 0x9b] + Array(repeating: 0, count: 8) {
            return isPublic(Array(b[12..<16]))
        }
        if b[0] & 0xfe == 0xfc { return false }                  // fc00::/7 unique local
        if b[0] == 0xfe && b[1] & 0xc0 == 0x80 { return false }  // fe80::/10 link local
        if b[0] == 0xfe && b[1] & 0xc0 == 0xc0 { return false }  // fec0::/10 site local
        if b[0] == 0xff { return false }                         // multicast
        return true
    }
}
