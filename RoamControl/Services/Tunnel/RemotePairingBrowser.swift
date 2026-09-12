import Foundation
import RoamPairingFFI

struct RemotePairingService: Sendable, Equatable {
    let port: UInt16
    let identifier: String
    let authTag: String
}

/// Finds this iPhone's own remote-pairing announcement. Several can be visible
/// at once — a stale one lingers after the tunnel is cycled — so each is checked
/// against the saved pairing record.
@MainActor
final class RemotePairingBrowser: NSObject {
    enum Event {
        case matched(RemotePairingService)
        /// A different, usually stale, pairing. Seeing only these is a distinct
        /// failure worth reporting differently.
        case unmatched
        case unavailable
    }

    private static let serviceType = "_remotepairing._tcp."
    private static let domain = "local."
    private static let resolveTimeout: TimeInterval = 8

    private let browser = NetServiceBrowser()
    private var resolvingServices: [NetService] = []
    private var pairingRecord: Data?
    private var handler: ((Event) -> Void)?

    private(set) var hasSeenUnmatchedService = false

    override init() {
        super.init()
        browser.includesPeerToPeer = true
    }

    var isSearching: Bool { handler != nil }

    func start(matching pairingRecord: Data, onEvent: @escaping (Event) -> Void) {
        stop()

        self.pairingRecord = pairingRecord
        self.handler = onEvent
        hasSeenUnmatchedService = false

        browser.delegate = self
        browser.searchForServices(ofType: Self.serviceType, inDomain: Self.domain)
    }

    func stop() {
        handler = nil
        pairingRecord = nil
        browser.stop()

        for service in resolvingServices {
            service.stopMonitoring()
            service.stop()
            service.remove(from: .main, forMode: .common)
            service.delegate = nil
        }
        resolvingServices = []
    }

    // MARK: - Resolution

    private func resolve(_ service: NetService) {
        guard isSearching else { return }

        service.delegate = self
        service.includesPeerToPeer = true
        service.schedule(in: .main, forMode: .common)
        service.resolve(withTimeout: Self.resolveTimeout)
        resolvingServices.append(service)
    }

    private func inspect(_ service: NetService) {
        guard isSearching, let pairingRecord, let announced = Self.announcement(from: service) else {
            return
        }

        guard Self.pairingRecord(pairingRecord, matches: announced) else {
            hasSeenUnmatchedService = true
            // Keep watching: a stale announcement often refreshes its TXT record
            // into the matching one rather than disappearing.
            service.startMonitoring()
            handler?(.unmatched)
            return
        }

        handler?(.matched(announced))
    }

    private static func announcement(from service: NetService) -> RemotePairingService? {
        guard service.port > 0, service.port <= Int(UInt16.max) else { return nil }
        guard let txtData = service.txtRecordData() else { return nil }

        let values = NetService.dictionary(fromTXTRecord: txtData)
        guard
            let identifierData = values["identifier"],
            let authTagData = values["authTag"]
        else { return nil }

        let identifier = String(decoding: identifierData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let authTag = String(decoding: authTagData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty, !authTag.isEmpty else { return nil }

        return RemotePairingService(
            port: UInt16(service.port),
            identifier: identifier,
            authTag: authTag
        )
    }

    private static func pairingRecord(_ record: Data, matches service: RemotePairingService) -> Bool {
        record.withUnsafeBytes { recordBytes in
            guard let recordBaseAddress = recordBytes.bindMemory(to: UInt8.self).baseAddress else {
                return false
            }

            return service.identifier.withCString { serviceIdentifier in
                service.authTag.withCString { serviceAuthTag in
                    rc_pairing_record_matches_service(
                        recordBaseAddress,
                        record.count,
                        serviceIdentifier,
                        serviceAuthTag
                    ) == 1
                }
            }
        }
    }
}

extension RemotePairingBrowser: NetServiceBrowserDelegate, NetServiceDelegate {
    nonisolated func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        MainActor.assumeIsolated {
            resolve(service)
        }
    }

    nonisolated func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didNotSearch errorDict: [String: NSNumber]
    ) {
        MainActor.assumeIsolated {
            handler?(.unavailable)
        }
    }

    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        MainActor.assumeIsolated {
            inspect(sender)
        }
    }

    nonisolated func netService(_ sender: NetService, didUpdateTXTRecord data: Data) {
        MainActor.assumeIsolated {
            inspect(sender)
        }
    }
}
