import Foundation
import Darwin
import HostsCore
import HelperProtocol

struct CheckFailure: Error, CustomStringConvertible { let description: String }
func expect(_ value: @autoclosure () throws -> Bool, _ message: String = "断言失败", file: StaticString = #filePath, line: UInt = #line) throws {
    if try !value() { throw CheckFailure(description: "\(file):\(line): \(message)") }
}
func expectThrows(_ body: () throws -> Void, line: UInt = #line) throws {
    do { try body() } catch { return }
    throw CheckFailure(description: "第 \(line) 行：预期操作被拒绝")
}

struct Fixture {
    let directory: URL
    let file: URL
    let backups: BackupStore
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("HostEditorChecks-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        file = directory.appendingPathComponent("hosts file")
        try Data("# original\r\n127.0.0.1 localhost alias\r\n::1 localhost".utf8).write(to: file)
        backups = BackupStore(root: directory.appendingPathComponent("backups", isDirectory: true))
    }
}
func withFixture(_ body: (Fixture) throws -> Void) throws {
    let fixture = try Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    try body(fixture)
}

let checks: [(String, () throws -> Void)] = [
    ("IPv6、别名、空白、注释和双栈", {
        let result = HostsSyntax.analyze("# hi\n127.0.0.1\tlocalhost alias # tail\n::1 localhost\n\n")
        try expect(result.diagnostics.isEmpty)
        try expect(result.tokens.filter { $0.kind == .comment }.count == 2)
    }),
    ("语法错误与警告分级", {
        let result = HostsSyntax.analyze("999.1.1.1 bad\n127.0.0.1\n127.0.0.1 name\n127.0.0.1 name\n127.0.0.2 name\n::1 name\n127.0.0.3 under_score\n")
        try expect(result.diagnostics.filter { $0.severity == .error }.map(\.line) == [1, 2])
        try expect(result.diagnostics.filter { $0.severity == .warning }.map(\.line) == [4, 5, 7])
    }),
    ("换行、末尾状态、权限与备份保真", { try withFixture { f in
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: f.file.path)
        let original = try FileStore.load(f.file.path)
        try expect(original.newline == "\r\n")
        let edited = original.editingText.replacingOccurrences(of: "alias", with: "other")
        let saved = try FileStore.save(original.encodedText(edited), expected: original, backups: f.backups)
        try expect(saved.text == "# original\r\n127.0.0.1 localhost other\r\n::1 localhost")
        let attrs = try FileManager.default.attributesOfItem(atPath: f.file.path)
        try expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o640)
        let records = try f.backups.list(path: original.canonicalPath)
        try expect(records.count == 1 && records[0].snapshot.data == original.data)
    }}),
    ("UTF-8 BOM 与未改动行的混合换行保真", { try withFixture { f in
        let raw = "\u{feff}# header\r\n127.0.0.1 one\n::1 two\r# end"
        try Data(raw.utf8).write(to: f.file)
        let base = try FileStore.load(f.file.path)
        try expect(!base.editingText.hasPrefix("\u{feff}"))
        try expect(base.encodedText(base.editingText) == base.data)
        let edited = "# inserted\n" + base.editingText
        let saved = try FileStore.save(base.encodedText(edited), expected: base, backups: f.backups)
        try expect(saved.text == "\u{feff}# inserted\r\n# header\r\n127.0.0.1 one\n::1 two\r# end")
    }}),
    ("扩展属性与所有者保留", { try withFixture { f in
        let attribute = Data("metadata-check".utf8)
        let status = attribute.withUnsafeBytes { setxattr(f.file.path, "com.hosteditor.check", $0.baseAddress, $0.count, 0, 0) }
        try expect(status == 0)
        let base = try FileStore.load(f.file.path)
        let oldAttrs = try FileManager.default.attributesOfItem(atPath: f.file.path)
        _ = try FileStore.save(Data("127.0.0.1 updated\n".utf8), expected: base, backups: f.backups)
        var buffer = [UInt8](repeating: 0, count: 128)
        let count = getxattr(f.file.path, "com.hosteditor.check", &buffer, buffer.count, 0, 0)
        try expect(count == attribute.count && Data(buffer.prefix(max(0, count))) == attribute)
        let newAttrs = try FileManager.default.attributesOfItem(atPath: f.file.path)
        try expect(oldAttrs[.ownerAccountID] as? NSNumber == newAttrs[.ownerAccountID] as? NSNumber)
        try expect(oldAttrs[.groupOwnerAccountID] as? NSNumber == newAttrs[.groupOwnerAccountID] as? NSNumber)
    }}),
    ("空文件与末行保存", { try withFixture { f in
        try Data().write(to: f.file)
        let base = try FileStore.load(f.file.path)
        try expect(base.editingText.isEmpty && HostsSyntax.analyze(base.editingText).diagnostics.isEmpty)
        _ = try FileStore.save(Data("::1 localhost\n".utf8), expected: base, backups: f.backups)
    }}),
    ("损坏的备份被拒绝", { try withFixture { f in
        let base = try FileStore.load(f.file.path)
        let record = try f.backups.create(base)
        let folder = f.backups.root.appendingPathComponent(digest(Data(base.canonicalPath.utf8)))
        let url = folder.appendingPathComponent(record.id + ".json")
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        json["id"] = "../../unexpected"
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        try expectThrows { _ = try f.backups.list(path: base.canonicalPath) }
    }}),
    ("外部内容冲突不覆盖", { try withFixture { f in
        let base = try FileStore.load(f.file.path)
        try Data("127.0.0.9 external\n".utf8).write(to: f.file)
        try expectThrows { _ = try FileStore.save(Data("127.0.0.8 local\n".utf8), expected: base, backups: f.backups) }
        try expect(try String(contentsOf: f.file) == "127.0.0.9 external\n")
    }}),
    ("单次管理员授权请求校验、权限验证与安全备份", { try withFixture { f in
        let snapshot = try FileStore.load(f.file.path)
        let authorized = OneShotRequest(operation: .authorize, snapshot: snapshot, contents: snapshot.data, uid: getuid())
        try expect(try authorized.perform(backups: f.backups) == "authorized")
        let updated = Data("127.0.0.1 updated\n".utf8)
        let request = OneShotRequest(operation: .save, snapshot: snapshot, contents: updated, uid: getuid())
        let encoded = try JSONEncoder().encode(request)
        let decoded = try OneShotRequest.decodeVerified(encoded, checksum: digest(encoded))
        try expect(try decoded.perform(backups: f.backups) == digest(updated))
        try expect(try FileStore.load(f.file.path).data == updated)
        try expect(try f.backups.list(path: snapshot.canonicalPath).count == 1)
        try expectThrows { _ = try OneShotRequest.decodeVerified(encoded, checksum: digest(Data("changed".utf8))) }
    }}),
    ("AppleScript 与 shell 参数安全转义", {
        try expect(CommandQuoting.shell("a'b") == "'a'\\''b'")
        try expect(CommandQuoting.appleScript("a\"b\\c\nd") == "\"a\\\"b\\\\c\\nd\"")
    }),
    ("相同内容替换文件仍检测冲突", { try withFixture { f in
        let base = try FileStore.load(f.file.path)
        try base.data.write(to: f.file, options: .atomic)
        try expectThrows { _ = try FileStore.save(base.data, expected: base, backups: f.backups) }
    }}),
    ("符号链接重定向被拒绝", { try withFixture { f in
        let link = f.directory.appendingPathComponent("hosts-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.file)
        let base = try FileStore.load(link.path)
        let other = f.directory.appendingPathComponent("other")
        try Data("127.0.0.2 other\n".utf8).write(to: other)
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: other)
        try expectThrows { _ = try FileStore.save(Data("127.0.0.3 overwrite\n".utf8), expected: base, backups: f.backups) }
        try expect(try String(contentsOf: other) == "127.0.0.2 other\n")
    }}),
    ("备份失败保持原文并清理临时文件", { try withFixture { f in
        let base = try FileStore.load(f.file.path)
        let blocked = f.directory.appendingPathComponent("not-directory"); try Data().write(to: blocked)
        try expectThrows { _ = try FileStore.save(Data("127.0.0.2 changed\n".utf8), expected: base, backups: BackupStore(root: blocked)) }
        try expect(try Data(contentsOf: f.file) == base.data)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: f.directory.path).filter { $0.hasPrefix(".hosteditor-") }
        try expect(leftovers.isEmpty)
    }}),
    ("无效编码、目录、FIFO 被拒绝", { try withFixture { f in
        try Data([0xff, 0xfe]).write(to: f.file)
        try expectThrows { _ = try FileStore.load(f.file.path) }
        try expectThrows { _ = try FileStore.load(f.directory.path) }
        let fifo = f.directory.appendingPathComponent("pipe")
        try expect(mkfifo(fifo.path, 0o600) == 0)
        try expectThrows { _ = try FileStore.load(fifo.path) }
    }}),
    ("备份保留、隔离与恢复", { try withFixture { f in
        var current = try FileStore.load(f.file.path); let canonical = current.canonicalPath
        for i in 0..<23 { current = try FileStore.save(Data("127.0.0.1 host\(i)\n".utf8), expected: current, backups: f.backups) }
        let records = try f.backups.list(path: canonical)
        try expect(records.count == 20)
        try expect(try f.backups.list(path: canonical + "-other").isEmpty)
        let restored = try FileStore.save(records[0].snapshot.data, expected: current, backups: f.backups)
        try expect(restored.data == records[0].snapshot.data)
        try expect(try f.backups.list(path: canonical).count == 20)
    }}),
    ("授权按路径隔离且拒绝畸形凭据", {
        try expect(FileAuthorization.rightName(path: "/private/etc/hosts") != FileAuthorization.rightName(path: "/tmp/hosts"))
        try expectThrows { try FileAuthorization.verify(Data(), path: "/private/etc/hosts") }
    }),
    ("hosts 文本编辑支持 Unicode 与原生编辑操作", {
        let text = "127.0.0.1 localhost # 👩🏽‍💻中文\n::1 localhost\n"
        try expect((text as NSString).range(of: "👩🏽‍💻").length > 0)
        try expect(HostsSyntax.analyze(text).diagnostics.isEmpty)
    })
]

var failures = 0
for (name, check) in checks {
    do { try check(); print("PASS \(name)") }
    catch { failures += 1; print("FAIL \(name): \(error)") }
}
print("\(checks.count - failures)/\(checks.count) checks passed")
if ProcessInfo.processInfo.arguments.contains("--benchmark") {
    do { try withFixture { f in
        var lines: [String] = [], size = 0, i = 0
        while size < 1024 * 1024 {
            let line = "127.0.0.1 host\(i).example.test # benchmark\n"
            lines.append(line); size += line.utf8.count; i += 1
        }
        let contents = lines.joined()
        try Data(contents.utf8).write(to: f.file)
        let start = DispatchTime.now().uptimeNanoseconds
        let snapshot = try FileStore.load(f.file.path)
        let loaded = DispatchTime.now().uptimeNanoseconds
        let result = HostsSyntax.analyze(contents)
        let analyzed = DispatchTime.now().uptimeNanoseconds
        let updated = snapshot.encodedText("# added line\n" + snapshot.editingText)
        let encoded = DispatchTime.now().uptimeNanoseconds
        try expect(result.diagnostics.isEmpty && updated.count > snapshot.data.count)
        print(String(format: "BENCHMARK %.2f MB: load %.1f ms, analyze %.1f ms, preserve-line-endings %.1f ms", Double(size) / 1048576, Double(loaded - start) / 1e6, Double(analyzed - loaded) / 1e6, Double(encoded - analyzed) / 1e6))
    }} catch { failures += 1; print("FAIL benchmark: \(error)") }
}
exit(failures == 0 ? 0 : 1)
