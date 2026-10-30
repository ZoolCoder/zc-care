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
}
