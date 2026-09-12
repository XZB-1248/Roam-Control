import NetworkExtension
import os

/// A loopback-only packet tunnel.
///
/// iOS will not serve this device's own `remotepairing` over loopback: a
/// connection to any local address short-circuits through `lo0`, which `remoted`
/// does not answer. Swapping source and destination and writing the packet back
/// makes it arrive as inbound traffic on the tunnel interface instead, which
/// `remoted` does serve. The same swap handles replies.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private static let deviceAddress = "10.7.0.0"
    private static let peerAddress = "10.7.0.1"
    private static let subnetMask = "255.255.255.252"

    private let log = Logger(subsystem: "com.clover.RoamControl.tunnel", category: "PacketTunnel")
    private var isRunning = false

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: Self.peerAddress)

        let ipv4Settings = NEIPv4Settings(
            addresses: [Self.deviceAddress],
            subnetMasks: [Self.subnetMask]
        )
        ipv4Settings.includedRoutes = [
            NEIPv4Route(destinationAddress: Self.peerAddress, subnetMask: "255.255.255.255")
        ]
        settings.ipv4Settings = ipv4Settings
        settings.mtu = 1500

        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self else {
                completionHandler(error)
                return
            }

            if let error {
                self.log.error("Tunnel settings were rejected: \(error.localizedDescription, privacy: .public)")
                completionHandler(error)
                return
            }

            self.isRunning = true
            self.log.info("Local tunnel active on \(Self.deviceAddress, privacy: .public) with peer \(Self.peerAddress, privacy: .public)")
            self.readPackets()
            completionHandler(nil)
        }
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        isRunning = false
        log.info("Local tunnel stopped (reason \(reason.rawValue, privacy: .public))")
        completionHandler()
    }

    private func readPackets() {
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self, self.isRunning else { return }

            var reflected: [Data] = []
            var reflectedProtocols: [NSNumber] = []
            reflected.reserveCapacity(packets.count)
            reflectedProtocols.reserveCapacity(packets.count)

            for (packet, protocolNumber) in zip(packets, protocols) {
                guard protocolNumber.int32Value == AF_INET,
                      let swapped = Self.swappingAddresses(in: packet)
                else { continue }

                reflected.append(swapped)
                reflectedProtocols.append(protocolNumber)
            }

            if !reflected.isEmpty {
                self.packetFlow.writePackets(reflected, withProtocols: reflectedProtocols)
            }

            self.readPackets()
        }
    }

    /// No checksum needs recomputing: the IPv4 header checksum and the TCP/UDP
    /// pseudo-header both fold the two addresses into a sum, so exchanging them
    /// changes nothing.
    private static func swappingAddresses(in packet: Data) -> Data? {
        guard packet.count >= 20 else { return nil }

        var swapped = packet
        guard swapped[swapped.startIndex] >> 4 == 4 else { return nil }

        swapped.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            let source = base.advanced(by: 12)
            let destination = base.advanced(by: 16)
            var scratch = [UInt8](repeating: 0, count: 4)
            memcpy(&scratch, source, 4)
            memcpy(source, destination, 4)
            memcpy(destination, &scratch, 4)
        }

        return swapped
    }
}
