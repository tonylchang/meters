import Darwin
import Foundation
import Synchronization
import SystemConfiguration

/// An interface as the network source sees it, before it decides whether to count it.
public struct NetworkInterface: Equatable, Sendable {
    public var name: String
    public var isUp: Bool
    public var isLoopback: Bool
    public var isPointToPoint: Bool
    /// The interface type from `net/if_types.h`, such as `IFT_ETHER` or `IFT_BRIDGE`.
    public var type: Int32
    public var counters: ByteCounters

    public init(
        name: String, isUp: Bool, isLoopback: Bool, isPointToPoint: Bool, type: Int32, counters: ByteCounters
    ) {
        self.name = name
        self.isUp = isUp
        self.isLoopback = isLoopback
        self.isPointToPoint = isPointToPoint
        self.type = type
        self.counters = counters
    }
}

public enum NetworkInterfaces {
    /// Interface types that never carry traffic of their own: bridges, and IPv6 tunnels.
    static let excludedTypes: Set<Int32> = [0xD1, 0x37, 0x39]  // IFT_BRIDGE, IFT_GIF, IFT_STF
    /// Virtual links whose traffic also crosses a physical interface.
    static let excludedPrefixes = ["utun", "ipsec", "gif", "stf", "bridge", "vmenet"]

    /// Whether an interface's traffic is counted: every interface that is up,
    /// except loopback, tunnels (VPN and similar point-to-point links), bridges, and virtual machine
    /// links, so the same traffic is never counted twice.
    public static func isCounted(_ interface: NetworkInterface) -> Bool {
        interface.isUp && !interface.isLoopback && !interface.isPointToPoint
            && !excludedTypes.contains(interface.type)
            && !excludedPrefixes.contains { interface.name.hasPrefix($0) }
    }
}

/// Documented source: per-interface 64-bit byte counters from the routing sysctl (`NET_RT_IFLIST2`).
/// Counters are keyed by interface name; `first` is bytes received, `second` bytes sent.
public final class SystemNetworkSource: ByteCounterSource {
    private struct NameCache {
        var wiFiInterfaces: Set<String> = []
        var counted: Set<String> = []
        var expires: ContinuousClock.Instant?
    }

    private let nameCache = Mutex(NameCache())

    public init() {}

    public func readSnapshot() -> ByteCounterSnapshot? {
        guard let counters = readCounters() else { return nil }
        let counted = Set(counters.keys)
        return nameCache.withLock { cache in
            let now = ContinuousClock.now
            if (cache.expires.map { now >= $0 } ?? true) || cache.counted != counted {
                cache.wiFiInterfaces = Self.readWiFiInterfaces()
                cache.counted = counted
                cache.expires = now + .seconds(30)
            }
            return Self.snapshot(counters: counters, wiFiInterfaces: cache.wiFiInterfaces)
        }
    }

    /// Show only Wi-Fi, once, while preserving every counted interface in the traffic total.
    static func snapshot(counters: [String: ByteCounters], wiFiInterfaces: Set<String>) -> ByteCounterSnapshot {
        let id = wiFiInterfaces.intersection(counters.keys).sorted().first
        return ByteCounterSnapshot(
            counters: counters, deviceNames: id.map { [$0: NetworkModuleText.wiFiDeviceName] } ?? [:])
    }

    /// Local interface types only; this API opens no network connections.
    private static func readWiFiInterfaces() -> Set<String> {
        guard let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return [] }
        var identifiers: Set<String> = []
        for interface in interfaces {
            guard let id = SCNetworkInterfaceGetBSDName(interface) as String?,
                let type = SCNetworkInterfaceGetInterfaceType(interface) as String?,
                type == kSCNetworkInterfaceTypeIEEE80211 as String
            else { continue }
            identifiers.insert(id)
        }
        return identifiers
    }

    public func readCounters() -> [String: ByteCounters]? {
        guard let interfaces = Self.readInterfaces() else { return nil }
        var counters: [String: ByteCounters] = [:]
        for interface in interfaces where NetworkInterfaces.isCounted(interface) {
            counters[interface.name] = interface.counters
        }
        return counters
    }

    /// Every interface the system reports, counted or not.
    public static func readInterfaces() -> [NetworkInterface]? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0 else { return nil }
        // Interfaces can appear between the two calls, so leave room.
        length += length / 8
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &length, nil, 0) == 0 else { return nil }

        return buffer.withUnsafeBytes { raw -> [NetworkInterface] in
            var interfaces: [NetworkInterface] = []
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                guard header.ifm_msglen > 0 else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2,
                    offset + MemoryLayout<if_msghdr2>.size <= length
                {
                    let message = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    // The interface's link-layer address follows its header and carries its name, so no
                    // separate lookup is needed (if_indextoname lists every interface on each call).
                    let addressOffset = offset + MemoryLayout<if_msghdr2>.size
                    let nameOffset = addressOffset + (MemoryLayout<sockaddr_dl>.offset(of: \.sdl_data) ?? 8)
                    if message.ifm_addrs & RTA_IFP != 0, addressOffset + MemoryLayout<sockaddr_dl>.size <= length {
                        let address = raw.loadUnaligned(fromByteOffset: addressOffset, as: sockaddr_dl.self)
                        let nameLength = Int(address.sdl_nlen)
                        if nameLength > 0, nameOffset + nameLength <= length {
                            let flags = Int32(message.ifm_flags)
                            interfaces.append(
                                NetworkInterface(
                                    name: String(
                                        decoding: raw[nameOffset..<(nameOffset + nameLength)], as: UTF8.self),
                                    isUp: flags & IFF_UP != 0,
                                    isLoopback: flags & IFF_LOOPBACK != 0, isPointToPoint: flags & IFF_POINTOPOINT != 0,
                                    type: Int32(message.ifm_data.ifi_type),
                                    counters: ByteCounters(
                                        first: message.ifm_data.ifi_ibytes, second: message.ifm_data.ifi_obytes)))
                        }
                    }
                }
                offset += Int(header.ifm_msglen)
            }
            return interfaces
        }
    }
}

/// The Network module's visible and spoken text, and its sparkline floor.
public enum NetworkModuleText {
    public static let label = "NET"
    public static let wiFiDeviceName = "Wi-Fi"
    public static let downloadMarker = "↓"
    public static let uploadMarker = "↑"
    public static let downloadAccessibilityLabel = "Network download"
    public static let uploadAccessibilityLabel = "Network upload"
    /// 100K: background chatter below this stays flat.
    public static let sparklineFloor: Double = 100_000
}
