import Foundation

/// How the Mac reaches the network: the service carrying the default route,
/// its addresses, the router and the DNS servers, as the dynamic store holds
/// them.
public struct Connection: Sendable, Equatable {
    public var service: String
    public var interface: String
    public var addresses: [String]
    public var subnetMask: String?
    public var router: String?
    public var dns: [String]
    public var searchDomains: [String]
    /// The proxies the system sends traffic through, as "HTTP 10.0.0.1:3128".
    public var proxies: [String] = []
    /// VPNs up beside the primary service, by name.
    public var tunnels: [String] = []

    /// Reads State:/Network/Global/IPv4, the primary service's IPv4 and IPv6
    /// state, State:/Network/Global/DNS and the service's setup. Nil without
    /// a primary interface. IPv6 link-local addresses are left out: every
    /// interface has one and nothing outside the link can reach it.
    public init?(global: [String: Any]?, ipv4: [String: Any]?, ipv6: [String: Any]?, dns: [String: Any]?,
                 setup: [String: Any]?) {
        guard let interface = global?["PrimaryInterface"] as? String, !interface.isEmpty else { return nil }
        let strings = { (dict: [String: Any]?, key: String) in dict?[key] as? [String] ?? [] }
        self.interface = interface
        service = setup?["UserDefinedName"] as? String ?? interface
        addresses = strings(ipv4, "Addresses")
            + strings(ipv6, "Addresses").filter { !$0.lowercased().hasPrefix("fe80:") }
        subnetMask = strings(ipv4, "SubnetMasks").first
        router = ipv4?["Router"] as? String ?? global?["Router"] as? String
        self.dns = strings(dns, "ServerAddresses")
        searchDomains = strings(dns, "SearchDomains")
    }

    /// The system proxies SCDynamicStoreCopyProxies reports as on, in words.
    /// Proxies a VPN sets for its own interface (`__SCOPED__`) are not read.
    public static func proxies(_ settings: [String: Any]?) -> [String] {
        guard let settings else { return [] }
        let on = { (key: String) in (settings[key] as? Int ?? 0) != 0 }
        var found: [String] = []
        for kind in ["HTTP", "HTTPS", "SOCKS", "FTP"] where on(kind + "Enable") {
            guard let host = settings[kind + "Proxy"] as? String, !host.isEmpty else { continue }
            let port = settings[kind + "Port"] as? Int
            found.append("\(kind) \(host)" + (port.map { ":\($0)" } ?? ""))
        }
        if on("ProxyAutoConfigEnable") {
            let url = settings["ProxyAutoConfigURLString"] as? String ?? ""
            found.append(url.isEmpty ? "Automatic configuration" : "Automatic configuration \(url)")
        }
        if on("ProxyAutoDiscoveryEnable") { found.append("Automatic discovery") }
        return found
    }

    /// The network services on a tunnel interface (utun, ipsec, ppp) other
    /// than the primary one: VPNs such as WireGuard, Tailscale or IKEv2. A
    /// VPN carrying all traffic is the primary service and named there.
    public static func tunnels(_ services: [(name: String?, interface: String)], primary: String) -> [String] {
        let names = services
            .filter { service in
                service.interface != primary && ["utun", "ipsec", "ppp"].contains { service.interface.hasPrefix($0) }
            }
            .map { $0.name ?? $0.interface }
        return Array(Set(names)).sorted()
    }
}
