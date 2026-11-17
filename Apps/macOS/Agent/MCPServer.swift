import Foundation
import Network
import OSLog
import ShakeUI
import Combine

@MainActor
final class MCPServer: ObservableObject {
    enum Status: Equatable {
        case stopped, starting, running, failed(String)
        var label: String {
            switch self {
            case .stopped: "已停止"
            case .starting: "正在启动"
            case .running: "运行中"
            case .failed: "启动失败"
            }
        }
    }

    nonisolated static let port: UInt16 = 17876
    nonisolated static let endpoint = "http://127.0.0.1:\(port)/mcp"
    private static let versions = ["2025-11-25", "2025-06-18", "2025-03-26"]
    private static let logger = Logger(subsystem: "cn.shake.lifelog", category: "Agent")

    @Published private(set) var status = Status.stopped
    @Published private(set) var logRevision = 0
    private let requestedPort: UInt16
    private let settings: UserDefaults?
    private static let enabledKey = "mcp.localReadEnabled"
    private(set) var boundPort: UInt16?
    private var listener: NWListener?

    init(port: UInt16 = MCPServer.port, settings: UserDefaults? = nil) {
        requestedPort = port
        self.settings = settings
    }
    private var connections: [UUID: NWConnection] = [:]
    private var requestWindow = (start: TimeInterval.zero, count: 0)
    private weak var cloud: CloudSettings?
    private var launched = false

    func launchIfNeeded(cloud: CloudSettings) {
        guard !launched else { return }
        launched = true
        self.cloud = cloud
        if settings?.bool(forKey: Self.enabledKey) == true { start() }
    }

    func start() {
        guard listener == nil else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: requestedPort) ?? .any)
            let listener = try NWListener(using: parameters)
            self.listener = listener
            status = .starting
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                Task { @MainActor in
                    guard let self, let listener, self.listener === listener else { return }
                    switch state {
                    case .ready:
                        self.boundPort = listener.port?.rawValue
                        self.status = .running
                        self.settings?.set(true, forKey: Self.enabledKey)
                    case .failed(let error):
                        self.closeListener()
                        self.status = .failed("无法监听本机端口 \(self.requestedPort)（\(error.localizedDescription)）。请释放端口后重试。")
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.start(queue: .main)
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func stop() {
        settings?.set(false, forKey: Self.enabledKey)
        closeListener()
        status = .stopped
    }

    private func closeListener() {
        listener?.cancel()
        listener = nil
        boundPort = nil
        disconnect()
    }

    func disconnect() {
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        requestWindow = (0, 0)
    }

    private func accept(_ connection: NWConnection) {
        guard listener != nil, connections.count < 32 else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        connection.start(queue: .main)
        receive(id, buffer: Data())
        Task {
            try? await Task.sleep(for: .seconds(8))
            close(id)
        }
    }

    private func receive(_ id: UUID, buffer: Data) {
        connections[id]?.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, self.connections[id] != nil else { return }
                if error != nil { self.close(id); return }
                var bytes = buffer
                if let data { bytes.append(data) }
                do {
                    if let request = try HTTPRequest.parse(bytes) {
                        self.send(self.respond(request), to: id)
                    } else if complete {
                        self.close(id)
                    } else {
                        self.receive(id, buffer: bytes)
                    }
                } catch {
                    self.send(HTTPResponse(400), to: id)
                }
            }
        }
    }

    private func close(_ id: UUID) { connections.removeValue(forKey: id)?.cancel() }

    private func send(_ response: HTTPResponse, to id: UUID) {
        connections[id]?.send(content: response.wire, completion: .contentProcessed { [weak self] _ in
            Task { @MainActor in self?.close(id) }
        })
    }

    private func respond(_ request: HTTPRequest) -> HTTPResponse {
        guard let port = boundPort else { return HTTPResponse(503) }
        let endpoint = "127.0.0.1:\(port)"
        guard request.headers["host"] == endpoint || request.headers["host"] == "localhost:\(port)" else {
            return HTTPResponse(403)
        }
        if let origin = request.headers["origin"], origin != "http://" + endpoint {
            return HTTPResponse(403)
        }
        guard request.path == "/mcp" else { return HTTPResponse(404) }
        guard let cloud, cloud.canServeAgent else { return HTTPResponse(503) }
        guard request.method == "POST" else { return HTTPResponse(405, headers: ["Allow": "POST"]) }
        if let version = request.headers["mcp-protocol-version"], !Self.versions.contains(version) {
            return HTTPResponse(400)
        }
        guard request.headers["content-type"]?.lowercased().hasPrefix("application/json") == true else {
            return HTTPResponse(415)
        }
        guard let message = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any],
              message["jsonrpc"] as? String == "2.0", let method = message["method"] as? String else {
            return rpcError(id: NSNull(), code: -32600, message: "Invalid request", status: 400)
        }
        guard rateAllowed() else { return HTTPResponse(429) }
        guard let id = message["id"] else { return HTTPResponse(202) }
        let params = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? Self.versions[0]
            let version = Self.versions.contains(requested) ? requested : Self.versions[0]
            return rpc(id: id, result: [
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "shake-life-log", "version": "2.0.0"]
            ])
        case "ping": return rpc(id: id, result: [:])
        case "tools/list": return rpc(id: id, result: ["tools": MCPTools.definitions])
        case "tools/call":
            guard let tool = params["name"] as? String else {
                return rpcError(id: id, code: -32602, message: "Missing tool name")
            }
            guard params["arguments"] == nil || params["arguments"] is [String: Any] else {
                return rpcError(id: id, code: -32602, message: "Tool arguments must be an object")
            }
            let snapshot = ShakeStoreSnapshot(repository: cloud.store.repository, media: cloud.store.media,
                                              status: cloud.status, dataAsOf: cloud.dataAsOf)
            do {
                let result = try MCPTools(store: snapshot)
                    .call(tool, params["arguments"] as? [String: Any] ?? [:])
                let encoded = try JSONSerialization.data(withJSONObject: result.data, options: [.sortedKeys, .withoutEscapingSlashes])
                var content: [[String: String]] = [["type": "text", "text": String(decoding: encoded, as: UTF8.self)]]
                for photo in result.photos {
                    content.append(["type": "image", "mimeType": "image/jpeg", "data": photo.base64EncodedString()])
                }
                try snapshot.repository.logAccess(tool: tool, count: result.count)
                Self.logger.info("mcp_tool_called")
                logRevision += 1
                return rpc(id: id, result: ["content": content, "structuredContent": result.data])
            } catch {
                return rpc(id: id, result: ["isError": true, "content": [["type": "text", "text": error.localizedDescription]]])
            }
        default: return rpcError(id: id, code: -32601, message: "Method not found")
        }
    }

    private func rateAllowed() -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        if now - requestWindow.start >= 60 { requestWindow = (now, 0) }
        guard requestWindow.count < 120 else { return false }
        requestWindow.count += 1
        return true
    }

    private func rpc(id: Any, result: [String: Any]) -> HTTPResponse {
        HTTPResponse(json: ["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func rpcError(id: Any, code: Int, message: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(json: ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]], status: status)
    }
}
