import AppKit
import Combine
import Network
import ShakeCore

@MainActor
final class LANReceiver: ObservableObject {
    nonisolated static let preferredPort: UInt16 = 17877
    @Published private(set) var pairing: LANPairing?
    @Published private(set) var expiresAt: Date?
    @Published private(set) var isStarting = false
    @Published private(set) var importedCount = 0
    @Published private(set) var skippedCount = 0
    @Published private(set) var rejectedCount = 0
    @Published private(set) var message: String?

    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var expiration: Task<Void, Never>?
    private let port: UInt16

    init(port: UInt16 = LANReceiver.preferredPort) { self.port = port }

    func start(importer: LANImporter, address: String? = nil, onImport: @escaping () -> Void) {
        stop()
        message = nil
        importedCount = 0
        skippedCount = 0
        rejectedCount = 0
        do {
            let address = try address ?? Self.localAddress()
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(address),
                                                         port: NWEndpoint.Port(rawValue: port) ?? .any)
            let listener = try NWListener(using: parameters)
            self.listener = listener
            isStarting = true
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                Task { @MainActor in
                    guard let self, let listener, self.listener === listener else { return }
                    switch state {
                    case .ready:
                        do {
                            guard let port = listener.port?.rawValue else { throw LANSyncError.receiverUnavailable }
                            try self.openPairing(address: address, port: port)
                        } catch {
                            self.stop()
                            self.message = error.localizedDescription
                        }
                    case .failed(let error):
                        self.stop()
                        self.message = "无法开启局域网接收。\(error.localizedDescription)"
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self, weak listener] connection in
                Task { @MainActor in
                    guard let self, let listener, self.listener === listener else { connection.cancel(); return }
                    self.accept(connection, importer: importer, onImport: onImport)
                }
            }
            listener.start(queue: .main)
        } catch {
            stop()
            message = error.localizedDescription
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        expiration?.cancel()
        expiration = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        pairing = nil
        expiresAt = nil
        isStarting = false
    }

    private func openPairing(address: String, port: UInt16) throws {
        let name = String((Host.current().localizedName ?? "Mac").prefix(40))
        pairing = try LANPairing(host: address, port: port, name: name.isEmpty ? "Mac" : name)
        expiresAt = Date.now.addingTimeInterval(600)
        isStarting = false
        expiration = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(600)) } catch { return }
            self?.stop()
            self?.message = "配对二维码已过期，请重新开启接收。"
        }
    }

    private func accept(_ connection: NWConnection, importer: LANImporter, onImport: @escaping () -> Void) {
        guard let pairing, let expiresAt, expiresAt > .now, connections.count < 4 else {
            connection.cancel()
            return
        }
        let id = UUID()
        connections[id] = connection
        connection.start(queue: .main)
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(25)) } catch { return }
            connection.cancel()
        }
        Task {
            defer {
                timeout.cancel()
                connections.removeValue(forKey: id)?.cancel()
            }
            do {
                let request = try await LANConnection.receive(over: connection, limit: LANWire.maxFrameBytes)
                guard self.pairing == pairing, expiresAt > .now else { return }
                if let ids = try? LANWire.openInventory(request, pairing: pairing) {
                    let missing = try importer.missingRecordIDs(ids)
                    let response = try LANWire.sealMissingIDs(missing, request: request, pairing: pairing)
                    try await LANConnection.send(response, over: connection)
                    if self.pairing == pairing { skippedCount += ids.count - missing.count }
                    return
                }
                let item = try LANWire.openRequest(request, pairing: pairing)
                let receipt: LANReceipt
                do {
                    receipt = try importer.importRecord(item)
                    if receipt == .imported { importedCount += 1; onImport() }
                    if receipt == .skipped { skippedCount += 1 }
                } catch {
                    rejectedCount += 1
                    receipt = .rejected
                }
                let response = try LANWire.sealReceipt(receipt, request: request, pairing: pairing)
                try await LANConnection.send(response, over: connection)
            } catch {
                // Unauthenticated traffic receives no response and does not change UI counters.
            }
        }
    }

    static func localAddress() throws -> String {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { throw LANSyncError.receiverUnavailable }
        defer { freeifaddrs(head) }
        var candidates: [(String, String)] = []
        var cursor = head
        while let current = cursor {
            let interface = current.pointee
            cursor = interface.ifa_next
            let name = String(cString: interface.ifa_name)
            guard name.hasPrefix("en"), interface.ifa_flags & UInt32(IFF_UP | IFF_RUNNING) == UInt32(IFF_UP | IFF_RUNNING),
                  let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let host = String(cString: buffer)
            if LANPairing.isLocalIPv4(host) { candidates.append((name, host)) }
        }
        let sorted = candidates.sorted {
            if $0.1.hasPrefix("169.254.") != $1.1.hasPrefix("169.254.") {
                return !$0.1.hasPrefix("169.254.")
            }
            return $0.0.localizedStandardCompare($1.0) == .orderedAscending
        }
        guard let host = sorted.first?.1 else {
            throw ShakeError.server("找不到可用的局域网地址。请将 Mac 连到与 iPhone 相同的 Wi-Fi。")
        }
        return host
    }
}
