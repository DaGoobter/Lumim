import Foundation

/// Finds Jellyfin servers on your home network, so signing in doesn't start with typing an address.
///
/// iPhone and Apple TV don't let apps send network-wide "who's there?" messages without a special Apple
/// permission, so this quickly asks every address on the home network (one request each, all at once, under
/// two seconds) for Jellyfin's public info.
enum ServerDiscovery {
    struct Found: Identifiable, Hashable {
        let id: String
        let name: String
        let address: String
        let version: String
    }

    static func scan() async -> [Found] {
        guard let (base, own) = localSubnet() else { return [] }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 1.5
        config.httpMaximumConnectionsPerHost = 2
        let session = URLSession(configuration: config)
        return await withTaskGroup(of: Found?.self) { group in
            for host in 1...254 where host != own {
                for port in [8096] {
                    group.addTask {
                        let address = "http://\(base).\(host):\(port)"
                        guard let url = URL(string: address + "/System/Info/Public"),
                              let (data, resp) = try? await session.data(from: url),
                              (resp as? HTTPURLResponse)?.statusCode == 200,
                              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let id = o["Id"] as? String else { return nil }
                        return Found(id: id, name: o["ServerName"] as? String ?? "Jellyfin",
                                     address: address, version: o["Version"] as? String ?? "")
                    }
                }
            }
            var out: [String: Found] = [:]
            for await f in group { if let f { out[f.id] = f } }
            return out.values.sorted { $0.name < $1.name }
        }
    }

    /// This device's home-network address, split into "192.168.1" and its own last number.
    private static func localSubnet() -> (String, Int)? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var best: (String, Int)?
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let i = p.pointee
            guard let sa = i.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: i.ifa_name)
            guard name.hasPrefix("en") else { continue }   // Wi-Fi / Ethernet
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            let parts = String(cString: host).split(separator: ".")
            guard parts.count == 4, let last = Int(parts[3]) else { continue }
            let a = Int(parts[0]) ?? 0, b = Int(parts[1]) ?? 0
            let isPrivate = a == 10 || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168)
            guard isPrivate else { continue }
            best = (parts[0...2].joined(separator: "."), last)
            if name == "en0" { break }
        }
        return best
    }
}
