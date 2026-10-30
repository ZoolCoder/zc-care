/// The Wi-Fi link the Mac is on, from CoreWLAN's numbers, put in words.
public struct WiFiLink: Sendable, Equatable {
    /// Signal and noise in dBm; noise is nil when the card has no reading.
    public var rssi: Int
    public var noise: Int?
    /// Mbps.
    public var rate: Double
    /// `CWPHYMode`, `CWSecurity`, `CWChannelBand` and `CWChannelWidth` raw values.
    public var phy: Int
    public var security: Int
    public var channel: Int
    public var band: Int
    public var width: Int

    public init(rssi: Int, noise: Int?, rate: Double, phy: Int, security: Int, channel: Int, band: Int, width: Int) {
        self.rssi = rssi
        self.noise = noise
        self.rate = rate
        self.phy = phy
        self.security = security
        self.channel = channel
        self.band = band
        self.width = width
    }

    public enum Quality: String, Sendable { case excellent = "Excellent", good = "Good", fair = "Fair", poor = "Poor" }

    /// The worse of what the signal strength and its margin over the noise
    /// say; a strong signal in a noisy room is not a good link.
    public var quality: Quality {
        let strength: Quality = rssi >= -50 ? .excellent : rssi >= -60 ? .good : rssi >= -70 ? .fair : .poor
        guard let noise else { return strength }
        let snr = rssi - noise
        let margin: Quality = snr >= 40 ? .excellent : snr >= 25 ? .good : snr >= 15 ? .fair : .poor
        let order: [Quality] = [.excellent, .good, .fair, .poor]
        return order[max(order.firstIndex(of: strength)!, order.firstIndex(of: margin)!)]
    }

    /// "Wi-Fi 6 (802.11ax)"; nil when CoreWLAN does not say.
    public var standard: String? {
        switch phy {
        case 1: "802.11a"
        case 2: "802.11b"
        case 3: "802.11g"
        case 4: "Wi-Fi 4 (802.11n)"
        case 5: "Wi-Fi 5 (802.11ac)"
        case 6: "Wi-Fi 6 (802.11ax)"
        case 7: "Wi-Fi 7 (802.11be)"
        default: nil
        }
    }

    /// "64 · 5 GHz · 40 MHz".
    public var channelText: String {
        var parts = ["\(channel)"]
        if let ghz = [1: "2.4 GHz", 2: "5 GHz", 3: "6 GHz"][band] { parts.append(ghz) }
        if let mhz = [1: "20 MHz", 2: "40 MHz", 3: "80 MHz", 4: "160 MHz"][width] { parts.append(mhz) }
        return parts.joined(separator: " · ")
    }

    public var securityText: String {
        [0: "None", 1: "WEP", 2: "WPA Personal", 3: "WPA/WPA2 Personal", 4: "WPA2 Personal", 5: "Personal",
         6: "Dynamic WEP", 7: "WPA Enterprise", 8: "WPA/WPA2 Enterprise", 9: "WPA2 Enterprise", 10: "Enterprise",
         11: "WPA3 Personal", 12: "WPA3 Enterprise", 13: "WPA2/WPA3 Personal", 14: "Enhanced Open", 15: "Enhanced Open (transition)"][security]
            ?? "Unknown"
    }

    /// Anyone nearby can read the traffic, or break the key in minutes:
    /// no encryption, WEP, or WPA without WPA2. Enhanced Open encrypts.
    public var isInsecure: Bool { [0, 1, 2, 6, 7].contains(security) }
}
