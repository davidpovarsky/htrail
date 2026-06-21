import Foundation

/// Finds this machine's LAN IPv4 address so an iPhone on the same Wi-Fi can
/// reach the proxy (127.0.0.1 only works for the Mac itself).
public enum LocalNetwork {
    public static func primaryIPv4() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var preferred: String?
        var fallback: String?
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let ptr = pointer {
            let interface = ptr.pointee
            let family = interface.ifa_addr.pointee.sa_family
            if family == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                var addr = interface.ifa_addr.pointee
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(&addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                            &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                let ip = String(cString: host)
                if ip != "127.0.0.1", !ip.hasPrefix("169.254") {
                    if name == "en0" { preferred = ip }
                    else if fallback == nil { fallback = ip }
                }
            }
            pointer = interface.ifa_next
        }
        address = preferred ?? fallback
        return address
    }
}
