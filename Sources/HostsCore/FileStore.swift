import Foundation
import CryptoKit
import Darwin
import FileSupport

public enum HostsError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}

public func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

public struct FileVersion: Codable, Equatable, Sendable {
    public let device: Int32
    public let inode: UInt64
    public let modifiedSeconds: Int64
    public let modifiedNanos: Int64
    public let changedSeconds: Int64
    public let changedNanos: Int64
    public let hash: String
    init(_ stat: stat, data: Data) {
        device = stat.st_dev; inode = stat.st_ino
        modifiedSeconds = Int64(stat.st_mtimespec.tv_sec); modifiedNanos = Int64(stat.st_mtimespec.tv_nsec)
        changedSeconds = Int64(stat.st_ctimespec.tv_sec); changedNanos = Int64(stat.st_ctimespec.tv_nsec)
        hash = digest(data)
    }
}

public struct FileSnapshot: Codable, Sendable {
    public let requestedPath: String
    public let canonicalPath: String
    public let data: Data
    public let version: FileVersion
    private enum CodingKeys: String, CodingKey { case requestedPath, canonicalPath, data, version }
    init(requestedPath: String, canonicalPath: String, data: Data, version: FileVersion) {
        self.requestedPath = requestedPath; self.canonicalPath = canonicalPath; self.data = data; self.version = version
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        requestedPath = try values.decode(String.self, forKey: .requestedPath)
        canonicalPath = try values.decode(String.self, forKey: .canonicalPath)
        data = try values.decode(Data.self, forKey: .data)
        version = try values.decode(FileVersion.self, forKey: .version)
        guard data.count <= FileStore.maximumSize, String(data: data, encoding: .utf8) != nil,
              digest(data) == version.hash, requestedPath.hasPrefix("/"), canonicalPath.hasPrefix("/"),
              !requestedPath.utf8.contains(0), !canonicalPath.utf8.contains(0) else { throw HostsError.message("文件快照或备份已损坏") }
    }
    public var text: String { String(decoding: data, as: UTF8.self) }
    public var newline: String { text.contains("\r\n") ? "\r\n" : text.contains("\r") ? "\r" : "\n" }
    public var editingText: String {
        let value = text.hasPrefix("\u{feff}") ? String(text.dropFirst()) : text
        return value.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }
    public func encodedText(_ edited: String) -> Data {
        if edited == editingText { return data }
        let originalLines = editingText.components(separatedBy: "\n")
        let editedLines = edited.components(separatedBy: "\n")
        let expression = try! NSRegularExpression(pattern: "\\r\\n|\\r|\\n")
        let ns = text as NSString
        let endings = expression.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
        let changes = editedLines.difference(from: originalLines)
        var inserted = Set<Int>(), removed = Set<Int>()
        for change in changes {
            switch change { case .insert(let offset, _, _): inserted.insert(offset); case .remove(let offset, _, _): removed.insert(offset) }
        }
        var originalIndex = 0
        let defaultEnding = newline
        var result = text.hasPrefix("\u{feff}") ? "\u{feff}" : ""
        for (index, line) in editedLines.enumerated() {
            var ending = defaultEnding
            if !inserted.contains(index) {
                while removed.contains(originalIndex) { originalIndex += 1 }
                if endings.indices.contains(originalIndex) { ending = endings[originalIndex] }
                originalIndex += 1
            }
            result += line
            if index < editedLines.count - 1 { result += ending }
        }
        return Data(result.utf8)
    }
}

public enum FileStore {
    public static let maximumSize = 32 * 1024 * 1024
    private static func failure(_ operation: String) -> HostsError { .message("\(operation)：\(String(cString: strerror(errno)))") }
    public static func canonical(_ path: String) throws -> String {
        guard path.hasPrefix("/"), !path.utf8.contains(0), let result = realpath(path, nil) else { throw failure("无法解析文件路径") }
        defer { free(result) }; return String(cString: result)
    }
    private static func bytes(_ fd: Int32) throws -> (Data, stat) {
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG else { throw HostsError.message("目标不是普通文件") }
        guard before.st_size <= maximumSize else { throw HostsError.message("文件超过 32 MB，无法安全打开；没有截断文件内容") }
        guard lseek(fd, 0, SEEK_SET) >= 0 else { throw failure("无法读取文件") }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 { if errno == EINTR { continue }; throw failure("读取失败") }
            if count == 0 { break }
            result.append(buffer, count: count)
            if result.count > maximumSize { throw HostsError.message("文件超过 32 MB，未读取完整内容") }
        }
        var after = stat()
        guard fstat(fd, &after) == 0,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw HostsError.message("读取期间文件发生变化，请重试") }
        return (result, after)
    }
    public static func load(_ path: String) throws -> FileSnapshot {
        let canonical = try canonical(path)
        let parent = he_open_parent(canonical)
        guard parent >= 0 else { throw failure("无法访问文件目录") }; defer { close(parent) }
        let fd = openat(parent, (canonical as NSString).lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw failure("无法打开文件") }; defer { close(fd) }
        let (data, info) = try bytes(fd)
        guard String(data: data, encoding: .utf8) != nil else { throw HostsError.message("文件不是有效 UTF-8，已禁止有损覆盖") }
        return FileSnapshot(requestedPath: path, canonicalPath: canonical, data: data, version: FileVersion(info, data: data))
    }

    /// Serializes our writers and rechecks content, identity and timestamps immediately before rename.
    public static func save(_ data: Data, expected: FileSnapshot, backups: BackupStore) throws -> FileSnapshot {
        guard data.count <= maximumSize, String(data: data, encoding: .utf8) != nil else { throw HostsError.message("写入内容过大或不是 UTF-8") }
        guard try canonical(expected.requestedPath) == expected.canonicalPath else { throw HostsError.message("路径指向已变化，拒绝保存") }
        let parent = he_open_parent(expected.canonicalPath)
        guard parent >= 0 else { throw failure("无法访问目录") }; defer { close(parent) }
        let name = (expected.canonicalPath as NSString).lastPathComponent
        let source = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard source >= 0 else { throw failure("无法打开目标") }; defer { close(source) }
        guard flock(source, LOCK_EX | LOCK_NB) == 0 else { throw HostsError.message("另一个写入操作正在进行，请稍后重试") }
        defer { flock(source, LOCK_UN) }
        let (old, info) = try bytes(source)
        guard FileVersion(info, data: old) == expected.version else { throw HostsError.message("磁盘文件已被外部修改，请重新加载或导出副本") }
        let temporary = ".hosteditor-\(UUID().uuidString)"
        let destination = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard destination >= 0 else { throw failure("无法创建安全临时文件") }
        defer { close(destination); unlinkat(parent, temporary, 0) }
        try data.withUnsafeBytes { raw in
            var remaining = raw.count, position = 0
            while remaining > 0 {
                let count = Darwin.write(destination, raw.baseAddress!.advanced(by: position), remaining)
                if count < 0 { if errno == EINTR { continue }; throw failure("写入失败") }
                guard count > 0 else { throw HostsError.message("写入未完成") }
                remaining -= count; position += count
            }
        }
        guard he_copy_metadata(source, destination) == 0 else { throw failure("无法保留文件权限或元数据") }
        guard fsync(destination) == 0 else { throw failure("无法同步文件数据") }
        _ = try backups.create(expected)
        let latest = try load(expected.requestedPath)
        guard latest.canonicalPath == expected.canonicalPath, latest.version == expected.version else { throw HostsError.message("保存期间目标发生变化，已中止写入") }
        var pathInfo = stat(), parentInfo = stat(), currentParentInfo = stat()
        let currentParent = he_open_parent(expected.canonicalPath)
        guard currentParent >= 0 else { throw failure("目录已改变") }; defer { close(currentParent) }
        guard fstat(parent, &parentInfo) == 0, fstat(currentParent, &currentParentInfo) == 0,
              parentInfo.st_dev == currentParentInfo.st_dev, parentInfo.st_ino == currentParentInfo.st_ino,
              fstatat(parent, name, &pathInfo, AT_SYMLINK_NOFOLLOW) == 0,
              pathInfo.st_dev == info.st_dev, pathInfo.st_ino == info.st_ino else { throw HostsError.message("文件或目录身份已变化，已中止写入") }
        guard renameat(parent, temporary, parent, name) == 0 else { throw failure("替换文件失败") }
        guard fsync(parent) == 0 else { throw failure("内容已替换但目录同步失败，请检查磁盘文件与备份") }
        let saved = try load(expected.requestedPath)
        guard saved.canonicalPath == expected.canonicalPath, saved.data == data else { throw HostsError.message("写入后文件再次变化，请检查磁盘版本；备份仍然保留") }
        try? backups.prune(path: expected.canonicalPath)
        return saved
    }
}

public struct BackupRecord: Codable, Sendable {
    public let id: String
    public let date: Date
    public let snapshot: FileSnapshot
}

public struct BackupStore: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root }
    public static var user: BackupStore {
        BackupStore(root: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("HostEditor/Backups", isDirectory: true))
    }
    private func directory(_ path: String) -> URL { root.appendingPathComponent(digest(Data(path.utf8)), isDirectory: true) }
    @discardableResult public func create(_ snapshot: FileSnapshot) throws -> BackupRecord {
        let folder = directory(snapshot.canonicalPath)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Existing directories must be private too. Reject symlinks rather than changing their targets.
        for url in [root, folder] {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attrs[.type] as? FileAttributeType == .typeDirectory,
                  (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { throw HostsError.message("备份目录所有者或类型不正确") }
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
        let record = BackupRecord(id: UUID().uuidString, date: Date(), snapshot: snapshot)
        let url = folder.appendingPathComponent(record.id + ".json")
        try JSONEncoder().encode(record).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return record
    }
    public func list(path: String) throws -> [BackupRecord] {
        let folder = directory(path)
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { url in
                let record = try JSONDecoder().decode(BackupRecord.self, from: Data(contentsOf: url))
                guard UUID(uuidString: record.id) != nil, url.deletingPathExtension().lastPathComponent == record.id else { throw HostsError.message("备份标识不正确") }
                return record
            }
            .filter { $0.snapshot.canonicalPath == path }
            .sorted { $0.date > $1.date }
    }
    public func prune(path: String) throws {
        for record in try list(path: path).dropFirst(20) {
            try FileManager.default.removeItem(at: directory(path).appendingPathComponent(record.id + ".json"))
        }
    }
}
