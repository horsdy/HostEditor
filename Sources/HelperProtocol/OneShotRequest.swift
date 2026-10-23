import Foundation
import Darwin
import HostsCore

/// The complete operation is bound to the system-approved command by its SHA-256.
public struct OneShotRequest: Codable {
    public enum Operation: String, Codable { case authorize, save }
    public let operation: Operation
    public let request: SaveRequest
    public let uid: uid_t
    public init(operation: Operation, snapshot: FileSnapshot, contents: Data, uid: uid_t) {
        self.operation = operation; self.request = SaveRequest(snapshot: snapshot, contents: contents); self.uid = uid
    }

    public static func decodeVerified(_ data: Data, checksum: String) throws -> OneShotRequest {
        guard data.count <= 100 * 1024 * 1024, digest(data) == checksum else {
            throw HostsError.message("授权请求已变化，已拒绝写入")
        }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.uid != 0, value.request.contents.count <= 32 * 1024 * 1024,
              String(data: value.request.contents, encoding: .utf8) != nil else {
            throw HostsError.message("授权请求无效")
        }
        return value
    }

    public func perform(backups: BackupStore) throws -> String {
        let expected = request.snapshot
        let current = try FileStore.load(expected.requestedPath)
        guard current.canonicalPath == expected.canonicalPath, current.version == expected.version else {
            throw HostsError.message("目标文件已变化，请重新加载后授权")
        }
        if operation == .authorize {
            let parent = URL(fileURLWithPath: expected.canonicalPath).deletingLastPathComponent().path
            guard access(expected.canonicalPath, W_OK) == 0, access(parent, W_OK) == 0 else {
                throw HostsError.message("系统仍不允许写入此文件或所在目录，请检查系统保护和磁盘状态")
            }
            return "authorized"
        }
        let saved = try FileStore.save(request.contents, expected: expected, backups: backups)
        return digest(saved.data)
    }
}

public enum CommandQuoting {
    public static func shell(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    public static func appleScript(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n") + "\""
    }
}
