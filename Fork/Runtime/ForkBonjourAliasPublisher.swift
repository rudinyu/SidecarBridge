#if SIDECARBRIDGE_FORK
import Foundation

/// Publishes the fork-specific direct-LAN service alongside the legacy
/// service exposed by NWListener. The alias always points at the listener's
/// confirmed port and is only a discovery hint; pairing authenticates peers.
final class ForkBonjourAliasPublisher: NSObject, NetServiceDelegate {
    enum Event {
        case published(port: UInt16, name: String)
        case failed(port: UInt16, error: Error)
        case stopped
    }

    var onEvent: ((Event) -> Void)?

    private var service: NetService?
    private var pendingPort: UInt16?
    private var pendingName: String?

    /// NetService is run-loop based, so all operations and delegate callbacks
    /// are confined to the main run loop.
    func publish(machineName: String?, port: UInt16, txtRecord: [String: String]) {
        DispatchQueue.main.async { [weak self] in
            self?.publishOnMain(machineName: machineName, port: port, txtRecord: txtRecord)
        }
    }

    func stop() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.service?.delegate = nil
            self.service?.stop()
            self.service = nil
            self.pendingPort = nil
            self.pendingName = nil
            self.onEvent?(.stopped)
        }
    }

    private func publishOnMain(machineName: String?, port: UInt16, txtRecord: [String: String]) {
        guard ForkRuntimeProfile.isSupportedListenerPort(port) else {
            onEvent?(.failed(
                port: port,
                error: POSIXError(.EINVAL)
            ))
            return
        }

        service?.delegate = nil
        service?.stop()
        service = nil

        let name = ForkRuntimeProfile.hostDisplayName(machineName: machineName)
        let nextService = NetService(
            domain: "local.",
            type: ForkRuntimeProfile.forkBonjourDirectServiceType + ".",
            name: name,
            port: Int32(port)
        )
        nextService.delegate = self
        nextService.includesPeerToPeer = true

        var record = txtRecord
        record[ForkRuntimeProfile.advertisedPortTXTKey] = String(port)
        let encodedRecord = record.mapValues { Data($0.utf8) }
        guard nextService.setTXTRecord(NetService.data(fromTXTRecord: encodedRecord)) else {
            nextService.delegate = nil
            onEvent?(.failed(
                port: port,
                error: POSIXError(.EINVAL)
            ))
            return
        }

        service = nextService
        pendingPort = port
        pendingName = name
        nextService.publish()
    }

    func netServiceDidPublish(_ sender: NetService) {
        guard service === sender,
              let port = pendingPort,
              let name = pendingName else {
            return
        }
        pendingPort = nil
        pendingName = nil
        onEvent?(.published(port: port, name: name))
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        guard service === sender, let port = pendingPort else { return }
        let errorCode = errorDict["NSNetServicesErrorCode"]?.intValue ?? -1
        let error = NSError(
            domain: NetService.errorDomain,
            code: errorCode,
            userInfo: [NSLocalizedDescriptionKey: "ScreenDock's direct Bonjour service could not be published."]
        )
        sender.delegate = nil
        sender.stop()
        service = nil
        pendingPort = nil
        pendingName = nil
        onEvent?(.failed(port: port, error: error))
    }

    deinit {
        let service = service
        DispatchQueue.main.async {
            service?.delegate = nil
            service?.stop()
        }
    }
}
#endif
