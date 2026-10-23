import Foundation
import Darwin
import HostsCore
import HelperProtocol

enum OneShotPermission {
    static func run(_ operation: OneShotRequest.Operation, snapshot: FileSnapshot, contents: Data,
                    completion: @escaping (Result<String, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { () throws -> String in
                let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/HelperTools/HostEditorHelper")
                let helperHash = digest(try Data(contentsOf: helper))
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HostEditor-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                defer { try? FileManager.default.removeItem(at: directory) }
                let file = directory.appendingPathComponent("request.json")
                let data = try JSONEncoder().encode(OneShotRequest(operation: operation, snapshot: snapshot, contents: contents, uid: getuid()))
                try data.write(to: file, options: [.atomic])
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                // Copy into a root-owned private directory, then verify the exact binary before execution.
                // No hosts data or user-supplied path is interpreted as shell code.
                let command = """
                set -eu
                umask 077
                task_dir=$(/usr/bin/mktemp -d /private/tmp/HostEditor-root.XXXXXXXX)
                trap '/bin/rm -f "$task_dir/helper"; /bin/rmdir "$task_dir"' EXIT
                /bin/cat \(CommandQuoting.shell(helper.path)) > "$task_dir/helper"
                actual=$(/usr/bin/shasum -a 256 "$task_dir/helper")
                [ "${actual%% *}" = \(CommandQuoting.shell(helperHash)) ] || { echo '辅助组件已变化，已拒绝执行' >&2; exit 1; }
                /bin/chmod 500 "$task_dir/helper"
                /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin "$task_dir/helper" --one-shot \(CommandQuoting.shell(file.path)) \(CommandQuoting.shell(digest(data)))
                """
                let script = "do shell script " + CommandQuoting.appleScript(command) + " with administrator privileges without altering line endings\n"
                let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-"]
                let input = Pipe(), output = Pipe(), errors = Pipe()
                process.standardInput = input; process.standardOutput = output; process.standardError = errors
                try process.run()
                input.fileHandleForWriting.write(Data(script.utf8)); try input.fileHandleForWriting.close()
                // The helper returns only a short acknowledgement or digest, never file contents.
                let reply = output.fileHandleForReading.readDataToEndOfFile()
                let error = errors.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    let detail = String(decoding: error, as: UTF8.self)
                    if detail.contains("-128") { throw HostsError.message("已取消系统授权；编辑内容已保留") }
                    throw HostsError.message("系统授权或写入失败；编辑内容已保留。\n" + detail)
                }
                return String(decoding: reply, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
}
