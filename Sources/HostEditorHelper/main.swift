import Foundation
import Security
import HostsCore
import HelperProtocol

final class HelperSession: NSObject, HostsHelperProtocol {
    let uid: uid_t
    // One serial queue for all connections prevents concurrent saves by this daemon.
    static let queue = DispatchQueue(label: "com.hosteditor.helper.saves")
    init(uid: uid_t) { self.uid = uid }
    func save(_ request: Data, authorization: Data, withReply reply: @escaping (Data?, String?) -> Void) {
        Self.queue.async {
            do {
                guard request.count <= 100 * 1024 * 1024 else { throw HostsError.message("请求过大") }
                let value = try JSONDecoder().decode(SaveRequest.self, from: request)
                let path = try FileStore.canonical(value.snapshot.requestedPath)
                guard path == value.snapshot.canonicalPath else { throw HostsError.message("目标路径指向已变化") }
                // Path-specific OS rights are required for every call, including custom paths.
                try FileAuthorization.verify(authorization, path: path)
                let backups = BackupStore(root: URL(fileURLWithPath: "/Library/Application Support/HostEditor/Backups/\(self.uid)", isDirectory: true))
                let saved = try FileStore.save(value.contents, expected: value.snapshot, backups: backups)
                reply(try JSONEncoder().encode(saved), nil)
            } catch { reply(nil, error.localizedDescription) }
        }
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Ad hoc development builds cannot expose a privileged endpoint.
        guard getuid() == 0, let team = SigningIdentity.teamID() else { return false }
        connection.setCodeSigningRequirement(SigningIdentity.requirement(identifier: appIdentifier, team: team))
        connection.exportedInterface = NSXPCInterface(with: HostsHelperProtocol.self)
        connection.exportedObject = HelperSession(uid: connection.effectiveUserIdentifier)
        connection.resume()
        return true
    }
}

if CommandLine.arguments.dropFirst().first == "--one-shot" {
    do {
        guard getuid() == 0, CommandLine.arguments.count == 4 else { throw HostsError.message("单次写入必须通过系统管理员认证") }
        let descriptor = open(CommandLine.arguments[2], O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw HostsError.message("无法读取授权请求") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_size <= 100 * 1024 * 1024 else { throw HostsError.message("授权请求文件无效") }
        let data = try handle.read(upToCount: 100 * 1024 * 1024 + 1) ?? Data()
        let request = try OneShotRequest.decodeVerified(data, checksum: CommandLine.arguments[3])
        guard info.st_uid == request.uid else { throw HostsError.message("授权请求所有者不匹配") }
        let backups = BackupStore(root: URL(fileURLWithPath: "/Library/Application Support/HostEditor/Backups/\(request.uid)", isDirectory: true))
        print(try request.perform(backups: backups))
        exit(0)
    } catch {
        FileHandle.standardError.write(Data(error.localizedDescription.utf8)); exit(1)
    }
} else {
    let delegate = ListenerDelegate()
    let listener = NSXPCListener(machServiceName: helperServiceName)
    listener.delegate = delegate
    listener.resume()
    RunLoop.current.run()
}
