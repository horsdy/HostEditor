import Foundation
import ServiceManagement
import Security
import HostsCore
import HelperProtocol

final class PermissionManager {
    let service = SMAppService.daemon(plistName: helperServiceName + ".plist")
    var available: Bool { SigningIdentity.teamID() != nil }
    var authenticated = false
    func canSaveDirectly(_ path: String) -> Bool {
        FileManager.default.isWritableFile(atPath: path) &&
            FileManager.default.isWritableFile(atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path)
    }
    var status: String {
        guard available else { return authenticated ? "系统认证已验证 · 受保护文件保存时按需授权" : "受保护文件可通过系统管理员认证写入" }
        switch service.status {
        case .enabled: return "授权服务已启用"
        case .requiresApproval: return "等待系统批准：请在登录项与扩展中允许 HostEditor"
        case .notRegistered: return "授权服务尚未安装"
        case .notFound: return "授权服务不可用：未找到辅助组件"
        @unknown default: return "未知授权状态"
        }
    }
    func register() throws {
        guard available else { return }
        if service.status != .enabled { try service.register() }
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }
    func unregister() throws {
        authenticated = false
        if service.status == .enabled || service.status == .requiresApproval { try service.unregister() }
    }
    func openSettings() { SMAppService.openSystemSettingsLoginItems() }

    func authorize(snapshot: FileSnapshot, completion: @escaping (Result<Void, Error>) -> Void) {
        if available {
            do { try register(); completion(.success(())) } catch { completion(.failure(error)) }
        } else {
            OneShotPermission.run(.authorize, snapshot: snapshot, contents: snapshot.data) { result in
                completion(result.flatMap { response in
                    guard response == "authorized" else { return .failure(HostsError.message("系统授权未返回确认")) }
                    self.authenticated = true
                    return .success(())
                })
            }
        }
    }

    func save(_ contents: Data, snapshot: FileSnapshot, completion: @escaping (Result<FileSnapshot, Error>) -> Void) {
        if !available {
            OneShotPermission.run(.save, snapshot: snapshot, contents: contents) { result in
                switch result {
                case .failure(let error): completion(.failure(error))
                case .success(let checksum):
                    DispatchQueue.global(qos: .userInitiated).async {
                        let verified = Result { () throws -> FileSnapshot in
                            let saved = try FileStore.load(snapshot.requestedPath)
                            guard saved.canonicalPath == snapshot.canonicalPath, saved.data == contents,
                                  checksum == digest(contents) else { throw HostsError.message("写入后文件已变化，请检查磁盘版本") }
                            return saved
                        }
                        DispatchQueue.main.async { self.authenticated = true; completion(verified) }
                    }
                }
            }
            return
        }
        guard service.status == .enabled, let team = SigningIdentity.teamID() else {
            completion(.failure(HostsError.message(status + "；请先在设置中授权并重新检查"))); return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let (auth, token) = try FileAuthorization.request(path: snapshot.canonicalPath)
                let connection = NSXPCConnection(machServiceName: helperServiceName, options: .privileged)
                connection.setCodeSigningRequirement(SigningIdentity.requirement(identifier: helperServiceName, team: team))
                connection.remoteObjectInterface = NSXPCInterface(with: HostsHelperProtocol.self)
                let gate = ReplyGate(connection: connection, authorization: auth, completion: completion)
                connection.invalidationHandler = { gate.finish(.failure(HostsError.message("授权服务连接已断开；请检查磁盘版本后重试"))) }
                connection.interruptionHandler = { gate.finish(.failure(HostsError.message("授权服务被中断；编辑内容已保留"))) }
                connection.resume()
                let proxy = connection.remoteObjectProxyWithErrorHandler { gate.finish(.failure($0)) } as? HostsHelperProtocol
                guard let proxy else { gate.finish(.failure(HostsError.message("无法连接授权服务"))); return }
                let request = try JSONEncoder().encode(SaveRequest(snapshot: snapshot, contents: contents))
                proxy.save(request, authorization: token) { data, error in
                    if let data {
                        do { gate.finish(.success(try JSONDecoder().decode(FileSnapshot.self, from: data))) }
                        catch { gate.finish(.failure(error)) }
                    } else { gate.finish(.failure(HostsError.message(error ?? "授权服务未返回结果"))) }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + 60) {
                    gate.finish(.failure(HostsError.message("保存等待超时，请检查磁盘版本再重试；编辑内容已保留")))
                }
            } catch { DispatchQueue.main.async { completion(.failure(error)) } }
        }
    }
}

private final class ReplyGate: @unchecked Sendable {
    let lock = NSLock()
    var completed = false
    let connection: NSXPCConnection
    let authorization: AuthorizationRef
    let completion: (Result<FileSnapshot, Error>) -> Void
    init(connection: NSXPCConnection, authorization: AuthorizationRef, completion: @escaping (Result<FileSnapshot, Error>) -> Void) {
        self.connection = connection; self.authorization = authorization; self.completion = completion
    }
    func finish(_ result: Result<FileSnapshot, Error>) {
        lock.lock()
        if completed { lock.unlock(); return }
        completed = true; lock.unlock()
        AuthorizationFree(authorization, .destroyRights)
        connection.invalidationHandler = nil; connection.interruptionHandler = nil; connection.invalidate()
        DispatchQueue.main.async { self.completion(result) }
    }
}
