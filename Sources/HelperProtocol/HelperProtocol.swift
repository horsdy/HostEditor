import Foundation
import Security
import HostsCore

public let helperServiceName = "com.hosteditor.app.helper"
public let appIdentifier = "com.hosteditor.app"

@objc public protocol HostsHelperProtocol {
    func save(_ request: Data, authorization: Data, withReply reply: @escaping (Data?, String?) -> Void)
}

public struct SaveRequest: Codable {
    public let snapshot: FileSnapshot
    public let contents: Data
    public init(snapshot: FileSnapshot, contents: Data) { self.snapshot = snapshot; self.contents = contents }
}

public enum FileAuthorization {
    public static func rightName(path: String) -> String { "com.hosteditor.write." + digest(Data(path.utf8)) }

    public static func request(path: String) throws -> (AuthorizationRef, Data) {
        var reference: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &reference) == errAuthorizationSuccess, let reference else {
            throw HostsError.message("无法创建系统授权会话")
        }
        do {
            let right = rightName(path: path)
            var definition: CFDictionary?
            if AuthorizationRightGet(right, &definition) != errAuthorizationSuccess {
                let rule: [String: Any] = ["class": "rule", "rule": ["authenticate-admin"]]
                let status = AuthorizationRightSet(reference, right, rule as CFDictionary,
                    "允许 HostEditor 写入 \(path)" as CFString, nil, nil)
                guard status == errAuthorizationSuccess else { throw HostsError.message("无法登记文件授权：\(status)") }
            }
            guard validRule(right) else { throw HostsError.message("文件授权规则异常，已拒绝提权；请联系管理员检查授权数据库") }
            let status = right.withCString { name -> OSStatus in
                var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
                return withUnsafeMutablePointer(to: &item) { pointer in
                    var rights = AuthorizationRights(count: 1, items: pointer)
                    return AuthorizationCopyRights(reference, &rights, nil, [.interactionAllowed, .extendRights], nil)
                }
            }
            guard status == errAuthorizationSuccess else { throw HostsError.message("系统授权被取消或拒绝（\(status)）；编辑内容已保留") }
            var external = AuthorizationExternalForm()
            guard AuthorizationMakeExternalForm(reference, &external) == errAuthorizationSuccess else { throw HostsError.message("无法传递系统授权") }
            return (reference, withUnsafeBytes(of: &external) { Data($0) })
        } catch {
            AuthorizationFree(reference, .destroyRights)
            throw error
        }
    }

    // Never accept a user-modified 'allow' rule for a privileged operation.
    public static func validRule(_ right: String) -> Bool {
        var definition: CFDictionary?
        guard AuthorizationRightGet(right, &definition) == errAuthorizationSuccess,
              let values = definition as? [String: Any], values["class"] as? String == "rule",
              values["rule"] as? [String] == ["authenticate-admin"] else { return false }
        return true
    }

    public static func verify(_ external: Data, path: String) throws {
        guard external.count == MemoryLayout<AuthorizationExternalForm>.size else { throw HostsError.message("授权数据无效") }
        var form = AuthorizationExternalForm()
        _ = withUnsafeMutableBytes(of: &form) { external.copyBytes(to: $0) }
        var reference: AuthorizationRef?
        guard AuthorizationCreateFromExternalForm(&form, &reference) == errAuthorizationSuccess, let reference else { throw HostsError.message("系统授权已失效") }
        defer { AuthorizationFree(reference, []) }
        let right = rightName(path: path)
        guard validRule(right) else { throw HostsError.message("授权规则不符合要求") }
        let status = right.withCString { name -> OSStatus in
            var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { pointer in
                var rights = AuthorizationRights(count: 1, items: pointer)
                return AuthorizationCopyRights(reference, &rights, nil, [], nil)
            }
        }
        guard status == errAuthorizationSuccess else { throw HostsError.message("未取得此文件的写入授权") }
    }
}

public enum SigningIdentity {
    public static func teamID() -> String? {
        var code: SecCode?, staticCode: SecStaticCode?, info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let team = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String,
              team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else { return nil }
        return team
    }
    public static func requirement(identifier: String, team: String) -> String {
        "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
    }
}
