import AppKit
import HostsCore

final class SettingsController: NSObject {
    unowned let app: AppController
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 420), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    let theme = NSPopUpButton()
    let path = NSTextField(string: "")
    let status = label("", size: 12, secondary: true)
    init(app: AppController) {
        self.app = app; super.init()
        window.title = "设置"; window.isReleasedWhenClosed = false; window.center()
        theme.addItems(withTitles: Theme.allCases.map(\.title)); theme.target = self; theme.action = #selector(changeTheme)
        theme.setAccessibilityLabel("主题")
        path.placeholderString = "/etc/hosts"; path.setAccessibilityLabel("hosts 文件路径")
        let choose = button("选择文件...", target: self, action: #selector(chooseFile))
        let apply = button("应用", target: self, action: #selector(applyPath))
        let reset = button("恢复默认路径", target: self, action: #selector(resetPath))
        status.maximumNumberOfLines = 2; status.lineBreakMode = .byWordWrapping
        var permissionButtons = [
            button("授权写入", target: app, action: #selector(AppController.authorizeAction)),
            button("重新检查", target: self, action: #selector(recheck))
        ]
        if app.permissions.available {
            permissionButtons += [button("打开系统设置", target: self, action: #selector(systemSettings)),
                                  button("卸载辅助组件", target: self, action: #selector(uninstall))]
        }
        let authorization = stack(permissionButtons, orientation: .horizontal, spacing: 8)
        let title = label("偏好设置", size: 22); title.font = .systemFont(ofSize: 22, weight: .semibold)
        let pathButtons = stack([choose, apply, reset], orientation: .horizontal, spacing: 8)
        let hint = label("自定义文件仅更改编辑目标；只有系统使用的 hosts 文件会影响本机解析。", size: 11, secondary: true)
        hint.maximumNumberOfLines = 2; hint.lineBreakMode = .byWordWrapping
        let content = stack([title, stack([label("主题"), theme], orientation: .horizontal),
            label("hosts 文件路径"), path, pathButtons, hint, label("权限管理"), status, authorization], spacing: 12)
        content.translatesAutoresizingMaskIntoConstraints = false; window.contentView!.addSubview(content)
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24), content.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24),
            path.widthAnchor.constraint(equalTo: content.widthAnchor), status.widthAnchor.constraint(equalTo: content.widthAnchor), hint.widthAnchor.constraint(equalTo: content.widthAnchor)])
        refresh()
    }
    func show() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    func refresh() {
        theme.selectItem(at: app.theme.rawValue)
        if path.currentEditor() == nil || window.firstResponder !== path.currentEditor() { path.stringValue = app.snapshot?.requestedPath ?? UserDefaults.standard.string(forKey: "hostsPath") ?? "/etc/hosts" }
        status.stringValue = app.permissions.status
    }
    @objc func changeTheme() { UserDefaults.standard.set(theme.indexOfSelectedItem, forKey: "theme"); app.applyTheme() }
    @objc func chooseFile() {
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { path.stringValue = url.path; applyPath() }
    }
    @objc func applyPath() {
        let candidate = path.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        app.openPath(candidate) { success in
            if success { UserDefaults.standard.set(candidate, forKey: "hostsPath") }
            self.path.stringValue = self.app.snapshot?.requestedPath ?? UserDefaults.standard.string(forKey: "hostsPath") ?? "/etc/hosts"
        }
    }
    @objc func resetPath() { path.stringValue = "/etc/hosts"; applyPath() }
    @objc func recheck() { refresh(); app.refreshStatus() }
    @objc func systemSettings() { app.permissions.openSettings() }
    @objc func uninstall() {
        guard !app.busy, app.confirm("卸载授权辅助组件？", detail: "卸载后不能通过辅助组件写入受保护文件；普通文件编辑不受影响。", button: "卸载") else { return }
        do { try app.permissions.unregister(); refresh(); app.refreshStatus() } catch { app.showError(error) }
    }
}
