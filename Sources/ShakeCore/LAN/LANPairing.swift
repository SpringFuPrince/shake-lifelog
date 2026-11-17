import CryptoKit
import Foundation

public struct LANPairing: Equatable, Sendable {
    public let host: String
    public let port: UInt16
    public let name: String
    let secret: Data

    public init(host: String, port: UInt16, name: String) throws {
        let key = SymmetricKey(size: .bits256)
        try self.init(host: host, port: port, name: name, secret: key.withUnsafeBytes { Data($0) })
    }

    private init(host: String, port: UInt16, name: String, secret: Data) throws {
        guard Self.isLocalIPv4(host), port != 0, secret.count == 32,
              !name.isEmpty, name.utf8.count <= 160 else { throw LANSyncError.invalidPairing }
        self.host = host
        self.port = port
        self.name = name
        self.secret = secret
    }

    public init(code: String) throws {
        guard code.utf8.count <= 1_024, let url = URLComponents(string: code),
              url.scheme == "shake-lan", url.user == nil, url.password == nil,
              url.fragment == nil, let host = url.host, let value = url.port,
              let port = UInt16(exactly: value),
              let fields = url.queryItems, fields.count == 2,
              let name = fields.first(where: { $0.name == "name" })?.value,
              let encoded = fields.first(where: { $0.name == "key" })?.value,
              let secret = Data(base64Encoded: encoded) else { throw LANSyncError.invalidPairing }
        guard url.path == "/v2" else { throw LANSyncError.incompatibleVersion }
        try self.init(host: host, port: port, name: name, secret: secret)
    }

    public var code: String {
        var url = URLComponents()
        url.scheme = "shake-lan"
        url.host = host
        url.port = Int(port)
        url.path = "/v2"
        url.queryItems = [.init(name: "name", value: name), .init(name: "key", value: secret.base64EncodedString())]
        return url.string!
    }

    public static func isLocalIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        let octets = parts.compactMap { part -> UInt8? in
            guard let value = UInt8(part), String(value) == part else { return nil }
            return value
        }
        guard parts.count == 4, octets.count == 4 else { return false }
        switch (octets[0], octets[1]) {
        case (10, _), (172, 16...31), (192, 168), (169, 254): return true
        default: return false
        }
    }
}

public enum LANSyncError: LocalizedError, Equatable {
    case invalidPairing, incompatibleVersion, invalidTransfer, missingPhoto, recordTooLarge, disconnected, timedOut, receiverUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalidPairing: "无法识别配对二维码。请扫描 Mac 拾刻显示的二维码。"
        case .incompatibleVersion: "请将 iPhone 和 Mac 上的拾刻都更新到支持增量同步的版本，再重新扫码。"
        case .invalidTransfer: "同步数据校验失败。请重新扫码后重试。"
        case .missingPhoto: "这条记录的照片还未就绪，暂时无法发送。"
        case .recordTooLarge: "这条记录或照片超过单条同步大小上限。"
        case .disconnected: "与 Mac 的连接已断开。请确认两台设备在同一 Wi-Fi，并保持接收页面打开。"
        case .timedOut: "连接 Mac 超时。请检查 Wi-Fi、局域网权限和 Mac 接收状态。"
        case .receiverUnavailable: "Mac 暂时无法接收。请重新开启接收并扫码。"
        }
    }
}
