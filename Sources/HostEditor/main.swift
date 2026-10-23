import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: AppController!
    var statusItem: NSStatusItem!
    var statusMenu: NSMenu!
    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = AppController()
        if let url = Bundle.main.url(forResource: "HostEditor", withExtension: "icns") {
            NSApp.applicationIconImage = NSImage(contentsOf: url)
        }
        buildMainMenu()
        statusMenu = makeActionsMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let image = Bundle.main.url(forResource: "HostEditor", withExtension: "icns").flatMap { NSImage(contentsOf: $0) }
            image?.size = NSSize(width: 20, height: 20)
            image?.accessibilityDescription = "HostEditor"
            button.image = image; button.toolTip = "HostEditor"
            button.target = self; button.action = #selector(statusClick)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        controller.statusChanged = { [weak self] in
            guard let self else { return }
            self.statusItem.button?.toolTip = self.controller.dirty ? "HostEditor · 有未保存修改" : "HostEditor"
        }
        controller.start()
    }
    private func item(_ title: String, action: Selector, key: String = "", target: AnyObject? = nil) -> NSMenuItem {
        let value = NSMenuItem(title: title, action: action, keyEquivalent: key); value.target = target ?? controller; return value
    }
    private func makeActionsMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("打开主窗口", action: #selector(AppController.showWindow)))
        menu.addItem(item("保存", action: #selector(AppController.saveAction), key: "s"))
        menu.addItem(.separator())
        menu.addItem(item("设置", action: #selector(AppController.showSettings), key: ","))
        menu.addItem(item("关于", action: #selector(AppController.showAbout)))
        menu.addItem(.separator())
        menu.addItem(item("退出 HostEditor", action: #selector(NSApplication.terminate(_:)), key: "q", target: NSApp))
        return menu
    }
    func buildMainMenu() {
        let main = NSMenu()
        let appMenu = NSMenu(title: "HostEditor")
        appMenu.addItem(item("关于 HostEditor", action: #selector(AppController.showAbout)))
        appMenu.addItem(item("设置", action: #selector(AppController.showSettings), key: ","))
        appMenu.addItem(.separator())
        appMenu.addItem(item("隐藏 HostEditor", action: #selector(NSApplication.hide(_:)), key: "h", target: NSApp))
        appMenu.addItem(item("退出 HostEditor", action: #selector(NSApplication.terminate(_:)), key: "q", target: NSApp))
        let appRoot = NSMenuItem(); appRoot.submenu = appMenu; main.addItem(appRoot)
        let file = NSMenu(title: "文件")
        file.addItem(item("保存", action: #selector(AppController.saveAction), key: "s"))
        file.addItem(item("重新加载", action: #selector(AppController.reloadAction)))
        file.addItem(item("导出副本", action: #selector(AppController.exportAction)))
        file.addItem(item("备份与恢复", action: #selector(AppController.showBackups)))
        file.addItem(.separator())
        file.addItem(item("关闭窗口", action: #selector(NSWindow.performClose(_:)), key: "w", target: nil))
        // This action follows the active window, including settings and about.
        file.items.last?.target = nil
        let fileRoot = NSMenuItem(); fileRoot.submenu = file; main.addItem(fileRoot)
        let edit = NSMenu(title: "编辑")
        for (title, selector, key) in [("撤销", "undo:", "z"), ("重做", "redo:", "Z"), ("剪切", "cut:", "x"), ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            edit.addItem(NSMenuItem(title: title, action: Selector(selector), keyEquivalent: key))
        }
        edit.addItem(item("查找", action: #selector(AppController.showFind), key: "f"))
        let editRoot = NSMenuItem(); editRoot.submenu = edit; main.addItem(editRoot)
        NSApp.mainMenu = main
    }
    @objc func statusClick() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            // Attach only while popping up, otherwise AppKit would intercept left clicks too.
            statusItem.menu = statusMenu; statusItem.button?.performClick(nil); statusItem.menu = nil
        } else { controller.showWindow() }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if controller.busy { return .terminateCancel }
        if !controller.dirty { return .terminateNow }
        DispatchQueue.main.async { self.controller.protectChanges { allowed in sender.reply(toApplicationShouldTerminate: allowed) } }
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller.showWindow()
        return true
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.setActivationPolicy(.regular)
application.delegate = delegate
application.run()
