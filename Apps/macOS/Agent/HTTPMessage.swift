import Foundation

struct HTTPRequest {
    private enum Failure: Error { case invalid }

    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    static func parse(_ data: Data) throws -> Self? {
        guard data.count <= 80_000 else { throw Failure.invalid }
        let delimiter = Data([13, 10, 13, 10])
        guard let end = data.range(of: delimiter) else {
            if data.count > 16_384 { throw Failure.invalid }
            return nil
        }
        guard end.lowerBound <= 16_384,
              let headerText = String(data: data[..<end.lowerBound], encoding: .utf8) else { throw Failure.invalid }
        let lines = headerText.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard requestLine.count == 3, requestLine[2] == "HTTP/1.1" else { throw Failure.invalid }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { throw Failure.invalid }
            let key = line[..<separator].lowercased()
            guard !key.isEmpty, key.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
                  headers[key] == nil else { throw Failure.invalid }
            headers[key] = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["transfer-encoding"] == nil,
              let length = Int(headers["content-length"] ?? "0"), (0...65_536).contains(length) else { throw Failure.invalid }
        let body = data[end.upperBound...]
        if body.count < length { return nil }
        guard body.count == length else { throw Failure.invalid }
        return Self(method: String(requestLine[0]), path: String(requestLine[1]), headers: headers, body: Data(body))
    }
}

struct HTTPResponse {
    let status: Int
    let headers: [String: String]
    let body: Data

    init(_ status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    init(json: [String: Any], status: Int = 200) {
        if JSONSerialization.isValidJSONObject(json), let data = try? JSONSerialization.data(withJSONObject: json) {
            self.init(status, headers: ["Content-Type": "application/json"], body: data)
        } else {
            self.init(500)
        }
    }

    var wire: Data {
        let reason = HTTPURLResponse.localizedString(forStatusCode: status)
        var head = "HTTP/1.1 \(status) \(reason)\r\nConnection: close\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\n"
        for (key, value) in headers { head += "\(key): \(value)\r\n" }
        return Data((head + "\r\n").utf8) + body
    }
}
