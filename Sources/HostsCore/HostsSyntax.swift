import Foundation
import Darwin

public struct Diagnostic: Equatable, Sendable {
    public enum Severity: String, Sendable { case error, warning }
    public let line: Int
    public let severity: Severity
    public let message: String
    public init(line: Int, severity: Severity, message: String) {
        self.line = line; self.severity = severity; self.message = message
    }
}

public struct SyntaxToken: Sendable {
    public enum Kind: Sendable { case address, hostname, comment }
    public let range: NSRange
    public let kind: Kind
}

public enum HostsSyntax {
    public static func addressFamily(_ value: String) -> Int32? {
        var v4 = in_addr(), v6 = in6_addr()
        if value.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 { return AF_INET }
        if value.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 { return AF_INET6 }
        return nil
    }

    public static func analyze(_ text: String) -> (tokens: [SyntaxToken], diagnostics: [Diagnostic]) {
        var tokens: [SyntaxToken] = [], diagnostics: [Diagnostic] = []
        var seen: [String: [Int32: Set<String>]] = [:]
        let ns = text as NSString
        var offset = 0, number = 1
        while offset < ns.length {
            let range = ns.lineRange(for: NSRange(location: offset, length: 0))
            let line = ns.substring(with: range) as NSString
            let comment = line.range(of: "#")
            let bodyLength = comment.location == NSNotFound ? line.length : comment.location
            if comment.location != NSNotFound {
                tokens.append(SyntaxToken(range: NSRange(location: offset + comment.location, length: line.length - comment.location), kind: .comment))
            }
            let body = line.substring(to: bodyLength)
            if body.unicodeScalars.contains(where: { ($0.value < 32 && ![9, 10, 13].contains($0.value)) || $0.value == 127 }) {
                diagnostics.append(Diagnostic(line: number, severity: .error, message: "包含不允许的控制字符"))
            }
            let fields = body.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            var search = NSRange(location: 0, length: bodyLength)
            for (index, field) in fields.enumerated() {
                let found = line.range(of: field, options: [], range: search)
                if found.location != NSNotFound {
                    tokens.append(SyntaxToken(range: NSRange(location: offset + found.location, length: found.length), kind: index == 0 ? .address : .hostname))
                    search = NSRange(location: NSMaxRange(found), length: bodyLength - NSMaxRange(found))
                }
            }
            if let address = fields.first {
                if let family = addressFamily(address) {
                    if fields.count < 2 { diagnostics.append(Diagnostic(line: number, severity: .error, message: "地址后缺少主机名")) }
                    for host in fields.dropFirst() {
                        let key = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                        let existing = seen[key]?[family] ?? []
                        if existing.contains(address) {
                            diagnostics.append(Diagnostic(line: number, severity: .warning, message: "重复映射：\(host)"))
                        } else if !existing.isEmpty {
                            diagnostics.append(Diagnostic(line: number, severity: .warning, message: "同一主机名存在同类地址冲突：\(host)"))
                        }
                        seen[key, default: [:]][family, default: []].insert(address)
                        if !plausibleHostname(host) { diagnostics.append(Diagnostic(line: number, severity: .warning, message: "请确认主机名格式：\(host)")) }
                    }
                } else {
                    diagnostics.append(Diagnostic(line: number, severity: .error, message: "无效的 IPv4 / IPv6 地址：\(address)"))
                }
            }
            offset = NSMaxRange(range); number += 1
        }
        return (tokens, diagnostics)
    }

    private static func plausibleHostname(_ host: String) -> Bool {
        let value = host.hasSuffix(".") ? String(host.dropLast()) : host
        return value.utf8.count <= 253 && value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0.utf8.count <= 63 && $0.first != "-" && $0.last != "-" && $0.unicodeScalars.allSatisfy {
                CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-").contains($0)
            }
        }
    }
}
