import AppKit
import HostsCore

enum Theme: Int, CaseIterable {
    case dark, light, system
    var title: String { ["深色", "浅色", "跟随系统"][rawValue] }
    var appearance: NSAppearance? {
        switch self { case .dark: return NSAppearance(named: .darkAqua); case .light: return NSAppearance(named: .aqua); case .system: return nil }
    }
}

func label(_ value: String, size: CGFloat = 13, secondary: Bool = false) -> NSTextField {
    let field = NSTextField(labelWithString: value)
    field.font = .systemFont(ofSize: size); field.textColor = secondary ? .secondaryLabelColor : .labelColor
    return field
}
func button(_ title: String, target: AnyObject, action: Selector) -> NSButton {
    let view = NSButton(title: title, target: target, action: action)
    view.bezelStyle = .rounded; view.setAccessibilityLabel(title)
    return view
}
func stack(_ views: [NSView], orientation: NSUserInterfaceLayoutOrientation = .vertical, spacing: CGFloat = 12) -> NSStackView {
    let view = NSStackView(views: views); view.orientation = orientation; view.alignment = orientation == .vertical ? .leading : .centerY; view.spacing = spacing
    return view
}

final class AppController: NSObject, NSWindowDelegate, NSTextViewDelegate, NSMenuItemValidation {
    let permissions = PermissionManager()
    let window = HostEditorWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 640), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    let editor = NSTextView(frame: .zero)
    let scroll = NSScrollView()
    let pathLabel = label("正在打开", size: 12, secondary: true)
    let permissionLabel = label("", size: 12, secondary: true)
    let statusLabel = label("", size: 11)
    let messageLabel = label("", size: 11, secondary: true)
    var saveButton: NSButton!
    var snapshot: FileSnapshot?
    var conflict = false
    var busy = false { didSet { editor.isEditable = !busy && snapshot != nil; refreshStatus() } }
    var saving = false
    var revision = 0
    var diagnostics: [Diagnostic] = []
    var tokens: [SyntaxToken] = []
    let analysisQueue = DispatchQueue(label: "com.hosteditor.analysis", qos: .userInitiated)
    var analysisTask: DispatchWorkItem?
    var watcher: DispatchSourceFileSystemObject?
    var folderWatcher: DispatchSourceFileSystemObject?
    var settings: SettingsController?
    var backupsWindow: BackupsController?
    var aboutWindow: NSWindow?
    var statusChanged: (() -> Void)?
    var theme: Theme { Theme(rawValue: UserDefaults.standard.integer(forKey: "theme")) ?? .dark }
    var dirty: Bool { guard let snapshot else { return false }; return editor.string != snapshot.editingText }

    override init() {
        super.init()
        UserDefaults.standard.register(defaults: ["theme": 0, "hostsPath": "/etc/hosts"])
        window.title = ""; window.minSize = NSSize(width: 720, height: 460)
        window.isReleasedWhenClosed = false; window.delegate = self; window.center()
        let root = NSView(); root.wantsLayer = true; window.contentView = root
        let subtitle = label("本机 hosts 编辑器", size: 12, secondary: true)
        pathLabel.lineBreakMode = .byClipping; pathLabel.maximumNumberOfLines = 1
        pathLabel.setAccessibilityLabel("当前 hosts 文件路径")
        pathLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let heading = stack([subtitle, pathLabel], orientation: .horizontal, spacing: 12)
        saveButton = button("保存  ⌘S", target: self, action: #selector(saveAction))
        saveButton.keyEquivalent = "s"
        let reload = button("重新加载", target: self, action: #selector(reloadAction))
        let backup = button("备份与恢复", target: self, action: #selector(showBackups))
        let settings = button("设置", target: self, action: #selector(showSettings))
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let toolbar = stack([heading, spacer, reload, backup, settings, saveButton], orientation: .horizontal, spacing: 8)
        permissionLabel.lineBreakMode = .byWordWrapping; permissionLabel.maximumNumberOfLines = 2
        let permissionButton = button("授权写入", target: self, action: #selector(authorizeAction))
        let exportButton = button("导出副本", target: self, action: #selector(exportAction))
        let info = stack([permissionLabel, NSView(), permissionButton, exportButton], orientation: .horizontal, spacing: 8)
        editor.isRichText = false; editor.importsGraphics = false; editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false; editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false; editor.isGrammarCheckingEnabled = false
        editor.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        editor.textContainerInset = NSSize(width: 16, height: 16)
        editor.minSize = NSSize(width: 0, height: 0)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.frame = NSRect(x: 0, y: 0, width: 850, height: 400)
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        editor.delegate = self; editor.usesFindBar = true; editor.isIncrementalSearchingEnabled = true
        scroll.findBarPosition = .aboveContent
        editor.setAccessibilityLabel("hosts 文件编辑器")
        scroll.documentView = editor; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        scroll.verticalRulerView = LineNumberRuler(scrollView: scroll, editor: editor)
        scroll.hasVerticalRuler = true; scroll.rulersVisible = true
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        statusLabel.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        messageLabel.lineBreakMode = .byClipping
        let footer = stack([statusLabel, NSView(), messageLabel], orientation: .horizontal, spacing: 12)
        let content = stack([toolbar, info, scroll, footer], spacing: 12)
        content.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20), content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: 18), content.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16)
        ])
        for view in [toolbar, info, scroll, footer] {
            view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        window.cancelFind = { [weak self] in
            guard let self, self.scroll.isFindBarVisible else { return false }
            self.scroll.isFindBarVisible = false
            self.window.makeFirstResponder(self.editor)
            return true
        }
        applyTheme()
        NotificationCenter.default.addObserver(self, selector: #selector(activated), name: NSApplication.didBecomeActiveNotification, object: nil)
        // Effective appearance changes include automatic system day/night changes.
        NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.applyEditorColors() }
        }.store(in: &appearanceObservation)
    }
    private var appearanceObservation: NSKeyValueObservation?

    func start() {
        let path = ProcessInfo.processInfo.environment["HOSTEDITOR_FILE"] ?? UserDefaults.standard.string(forKey: "hostsPath") ?? "/etc/hosts"
        openPath(path, protect: false)
        showWindow()
    }
    @objc func showWindow() {
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func applyTheme() {
        NSApp.appearance = theme.appearance
        [window, settings?.window, backupsWindow?.window, aboutWindow].compactMap { $0 }.forEach { $0.appearance = theme.appearance }
        applyEditorColors()
        for view in [window.contentView, settings?.window.contentView, backupsWindow?.window.contentView, aboutWindow?.contentView].compactMap({ $0 }) { view.needsDisplay = true }
    }
    func applyEditorColors() {
        editor.backgroundColor = .textBackgroundColor; editor.textColor = .textColor; editor.insertionPointColor = .controlAccentColor
        highlightVisible(); scroll.verticalRulerView?.needsDisplay = true
    }
    func refreshStatus() {
        let text = editor.string as NSString, position = min(editor.selectedRange().location, text.length)
        let prefix = text.substring(to: position)
        let row = prefix.filter { $0 == "\n" }.count + 1
        let line = text.lineRange(for: NSRange(location: position, length: 0))
        let column = text.substring(with: NSRange(location: line.location, length: position - line.location)).count + 1
        statusLabel.stringValue = "\(row):\(column)\(dirty ? "   ● 未保存" : "")"
        window.isDocumentEdited = dirty
        if busy { permissionLabel.stringValue = saving ? "正在校验与保存" : "正在读取文件" }
        else if conflict { permissionLabel.stringValue = "⚠ 磁盘版本已改变。请查看磁盘版本、重新加载或导出当前副本。" }
        else if let snapshot {
            let writable = permissions.canSaveDirectly(snapshot.canonicalPath)
            permissionLabel.stringValue = writable ? "可直接保存  ·  保存前自动备份" : "保存需要授权  ·  \(permissions.status)"
        } else { permissionLabel.stringValue = "文件不可访问；可在设置中选择其他文件" }
        saveButton?.isEnabled = dirty && !busy && !conflict
        statusChanged?()
    }
    func textDidChange(_ notification: Notification) { revision += 1; scheduleAnalysis(); refreshStatus() }
    func textViewDidChangeSelection(_ notification: Notification) { refreshStatus(); highlightVisible() }
    @objc func scrolled() { highlightVisible(); scroll.verticalRulerView?.needsDisplay = true }
    func scheduleAnalysis() {
        analysisTask?.cancel()
        let text = editor.string, version = revision
        let task = DispatchWorkItem { [weak self] in
            let result = HostsSyntax.analyze(text)
            DispatchQueue.main.async {
                guard let self, self.revision == version else { return }
                self.tokens = result.tokens; self.diagnostics = result.diagnostics
                self.messageLabel.stringValue = result.diagnostics.first.map { "第 \($0.line) 行：\($0.message)（共 \(result.diagnostics.count) 项）" } ?? "语法检查通过"
                self.highlightVisible(); self.scroll.verticalRulerView?.needsDisplay = true
            }
        }
        analysisTask = task; analysisQueue.asyncAfter(deadline: .now() + 0.12, execute: task)
    }
    func highlightVisible() {
        guard let layout = editor.layoutManager, let container = editor.textContainer else { return }
        let length = (editor.string as NSString).length
        let range = NSRange(location: 0, length: length)
        layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
        let line = (editor.string as NSString).lineRange(for: NSRange(location: min(editor.selectedRange().location, length), length: 0))
        if line.length > 0 { layout.addTemporaryAttribute(.backgroundColor, value: NSColor.controlAccentColor.withAlphaComponent(0.07), forCharacterRange: line) }
        let glyphs = layout.glyphRange(forBoundingRect: editor.visibleRect, in: container)
        let visible = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: visible)
        layout.removeTemporaryAttribute(.underlineStyle, forCharacterRange: visible)
        for token in tokens where NSIntersectionRange(token.range, visible).length > 0 && NSMaxRange(token.range) <= length {
            let color: NSColor
            switch token.kind { case .address: color = .systemCyan; case .hostname: color = .systemOrange; case .comment: color = .secondaryLabelColor }
            layout.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: token.range)
        }
        if diagnostics.contains(where: { $0.severity == .error }) {
            let ns = editor.string as NSString
            var number = 1, position = 0
            let errors = Set(diagnostics.filter { $0.severity == .error }.map(\.line))
            while position < length {
                let line = ns.lineRange(for: NSRange(location: position, length: 0))
                if errors.contains(number), NSIntersectionRange(line, visible).length > 0 {
                    layout.addTemporaryAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue, .underlineColor: NSColor.systemRed], forCharacterRange: line)
                }
                position = NSMaxRange(line); number += 1
            }
        }
    }
    func openPath(_ path: String, protect: Bool = true, completion: ((Bool) -> Void)? = nil) {
        guard !busy else { completion?(false); return }
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try FileStore.load(path) }
            DispatchQueue.main.async {
                self.busy = false
                switch result {
                case .failure(let error): self.showError(error); completion?(false)
                case .success(let snapshot):
                    if snapshot.data.count > 1024 * 1024 && !self.confirm("文件较大", detail: "文件超过 1 MB，高亮和编辑可能变慢。是否继续？", button: "继续打开") { completion?(false); return }
                    let apply: () -> Void = {
                        self.snapshot = snapshot; self.conflict = false
                        self.editor.isEditable = true
                        self.editor.string = snapshot.editingText; self.editor.undoManager?.removeAllActions()
                        self.editor.setSelectedRange(NSRange(location: 0, length: 0))
                        self.pathLabel.stringValue = snapshot.requestedPath; self.pathLabel.toolTip = snapshot.canonicalPath
                        self.revision += 1; self.tokens = []; self.diagnostics = []; self.scheduleAnalysis(); self.refreshStatus(); self.watchFile()
                        completion?(true)
                    }
                    if protect && self.dirty {
                        self.protectChanges { allowed in
                            // Saving the old buffer may itself change this path; read again after the decision.
                            if allowed { self.openPath(path, protect: false, completion: completion) }
                            else { completion?(false) }
                        }
                    }
                    else { apply() }
                }
            }
        }
    }
    @objc func reloadAction() {
        guard let snapshot else { return }
        openPath(snapshot.requestedPath)
    }
    @objc func activated() { refreshStatus(); settings?.refresh(); checkExternal() }
    func watchFile() {
        watcher?.cancel(); folderWatcher?.cancel()
        guard let snapshot else { return }
        func source(_ path: String) -> DispatchSourceFileSystemObject? {
            let fd = open(path, O_EVTONLY | O_CLOEXEC)
            guard fd >= 0 else { return nil }
            let value = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .attrib, .extend], queue: .main)
            value.setEventHandler { [weak self] in self?.checkExternal() }
            value.setCancelHandler { close(fd) }; value.resume(); return value
        }
        watcher = source(snapshot.canonicalPath)
        folderWatcher = source((snapshot.canonicalPath as NSString).deletingLastPathComponent)
    }
    func checkExternal() {
        guard !busy, let base = snapshot else { return }
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try FileStore.load(base.requestedPath) }
            DispatchQueue.main.async {
                guard !self.busy, self.snapshot?.version == base.version else { return }
                switch result {
                case .success(let latest):
                    guard latest.version != base.version || latest.canonicalPath != base.canonicalPath else { return }
                    if self.dirty || latest.canonicalPath != base.canonicalPath { self.conflict = true; self.refreshStatus() }
                    else {
                        self.snapshot = latest; self.editor.string = latest.editingText; self.editor.undoManager?.removeAllActions()
                        self.revision += 1; self.tokens = []; self.scheduleAnalysis(); self.refreshStatus(); self.watchFile()
                        self.messageLabel.stringValue = "已重新读取外部修改"
                    }
                case .failure: self.conflict = true; self.refreshStatus()
                }
            }
        }
    }
    @objc func saveAction() { save() }
    func save(restoring: Data? = nil, completion: ((Bool) -> Void)? = nil) {
        guard !busy, let snapshot else { completion?(false); return }
        guard !conflict else { showError(HostsError.message("存在外部修改，请重新加载或导出当前副本")); completion?(false); return }
        guard dirty || restoring != nil else { messageLabel.stringValue = "无需保存"; completion?(true); return }
        let text = editor.string
        saving = true; busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let data = restoring ?? snapshot.encodedText(text)
            let issues = restoring == nil ? HostsSyntax.analyze(String(data: data, encoding: .utf8)!).diagnostics : []
            let check = Result { try FileStore.load(snapshot.requestedPath) }
            DispatchQueue.main.async {
                let failed: (Error) -> Void = { error in self.saving = false; self.busy = false; self.showError(error); completion?(false) }
                if let error = issues.first(where: { $0.severity == .error }) { failed(HostsError.message("第 \(error.line) 行：\(error.message)；请修正后保存，或导出副本")); return }
                if !issues.isEmpty && !self.confirm("存在 \(issues.count) 项警告", detail: issues.prefix(8).map { "第 \($0.line) 行：\($0.message)" }.joined(separator: "\n"), button: "仍然保存") {
                    self.saving = false; self.busy = false; completion?(false); return
                }
                switch check {
                case .failure(let error): failed(error); return
                case .success(let latest):
                    guard latest.version == snapshot.version, latest.canonicalPath == snapshot.canonicalPath else {
                        self.conflict = true; failed(HostsError.message("磁盘文件已改变，已中止保存")); return
                    }
                }
                let finish: (Result<FileSnapshot, Error>) -> Void = { result in
                    self.saving = false; self.busy = false
                    switch result {
                    case .success(let saved):
                        self.snapshot = saved; self.conflict = false
                        if restoring != nil { self.editor.string = saved.editingText; self.editor.undoManager?.removeAllActions(); self.revision += 1; self.scheduleAnalysis() }
                        self.messageLabel.stringValue = "已保存 · \(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium))"
                        self.refreshStatus(); self.watchFile(); completion?(true)
                    case .failure(let error): self.showError(error); self.checkExternal(); completion?(false)
                    }
                }
                if self.permissions.canSaveDirectly(snapshot.canonicalPath) {
                    DispatchQueue.global(qos: .userInitiated).async {
                        let result = Result { try FileStore.save(data, expected: snapshot, backups: .user) }
                        DispatchQueue.main.async { finish(result) }
                    }
                } else {
                    if self.permissions.available && self.permissions.service.status != .enabled {
                        do {
                            guard self.confirm("需要系统授权", detail: "HostEditor 将安装受限的写入辅助组件。系统可能要求在登录项与扩展中批准；每个受保护文件还需要单独授权。", button: "继续授权") else { self.saving = false; self.busy = false; completion?(false); return }
                            try self.permissions.register()
                            guard self.permissions.service.status == .enabled else { throw HostsError.message(self.permissions.status + "；批准后重新点击保存") }
                        } catch { failed(error); return }
                    }
                    DispatchQueue.global(qos: .userInitiated).async {
                        do {
                            // Keep a user-accessible backup as well as the daemon's private safety copy.
                            try BackupStore.user.create(snapshot)
                            DispatchQueue.main.async { self.permissions.save(data, snapshot: snapshot) { result in
                                if case .success = result { try? BackupStore.user.prune(path: snapshot.canonicalPath) }
                                finish(result)
                            } }
                        } catch { DispatchQueue.main.async { failed(error) } }
                    }
                }
            }
        }
    }
    func protectChanges(_ completion: @escaping (Bool) -> Void) {
        guard !busy else { completion(false); return }
        guard dirty else { completion(true); return }
        let alert = NSAlert(); alert.messageText = "保存对 hosts 的修改？"; alert.informativeText = "未保存的修改将被丢弃。"
        alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "不保存"); alert.addButton(withTitle: "取消")
        switch alert.runModal() {
        case .alertFirstButtonReturn: save(completion: completion)
        case .alertSecondButtonReturn: completion(true)
        default: completion(false)
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        protectChanges { allowed in
            if allowed {
                if self.dirty, let snapshot = self.snapshot {
                    self.editor.string = snapshot.editingText; self.editor.undoManager?.removeAllActions()
                    self.revision += 1; self.tokens = []; self.scheduleAnalysis(); self.refreshStatus()
                }
                self.window.orderOut(nil)
            }
        }
        return false
    }
    @objc func exportAction() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "hosts-copy.txt"
        if panel.runModal() == .OK, let url = panel.url {
            do { try (snapshot?.encodedText(editor.string) ?? Data(editor.string.utf8)).write(to: url, options: .atomic) }
            catch { showError(error) }
        }
    }
    @objc func authorizeAction() {
        guard !busy, let snapshot else { return }
        let detail = permissions.available
            ? "安装受限辅助组件；实际保存时由系统批准当前文件的写入。"
            : "将打开 macOS 管理员认证，验证当前文件的写入权限。本次不会修改文件；保存受保护文件时按需再次认证。\n目标：\(snapshot.canonicalPath)"
        guard confirm("授权写入受保护的 hosts 文件", detail: detail, button: "继续") else { return }
        busy = true
        permissions.authorize(snapshot: snapshot) { result in
            self.busy = false; self.refreshStatus(); self.settings?.refresh()
            switch result {
            case .success: self.messageLabel.stringValue = self.permissions.status
            case .failure(let error): self.showError(error)
            }
        }
    }
    @objc func showSettings() {
        if settings == nil { settings = SettingsController(app: self) }
        settings?.refresh(); settings?.show(); applyTheme()
    }
    @objc func showBackups() {
        guard !busy, let snapshot else { return }
        if backupsWindow == nil { backupsWindow = BackupsController(app: self) }
        backupsWindow?.load(path: snapshot.canonicalPath); backupsWindow?.show(); applyTheme()
    }
    func restore(_ record: BackupRecord) {
        guard let snapshot, record.snapshot.canonicalPath == snapshot.canonicalPath else { showError(HostsError.message("备份不属于当前目标文件")); return }
        protectChanges { allowed in
            guard allowed else { return }
            guard self.confirm("恢复此备份？", detail: "恢复前会备份当前磁盘内容。历史内容将按原样写入；请先确认预览。", button: "恢复") else { return }
            self.save(restoring: record.snapshot.data) { success in if success { self.backupsWindow?.load(path: snapshot.canonicalPath) } }
        }
    }
    @objc func showAbout() {
        if aboutWindow == nil {
            func aboutLabel(_ value: String, size: CGFloat = 13, secondary: Bool = false) -> NSTextField {
                let field = label(value, size: size, secondary: secondary)
                field.isSelectable = true
                return field
            }
            let about = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 280), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            about.title = "关于 HostEditor"; about.isReleasedWhenClosed = false; about.center()
            let bundle = Bundle.main
            let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
            let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
            let system = ProcessInfo.processInfo.operatingSystemVersion
            let macOSVersion = "macOS \(system.majorVersion).\(system.minorVersion).\(system.patchVersion)"
            let title = aboutLabel("HostEditor", size: 26); title.font = .systemFont(ofSize: 26, weight: .semibold)
            let content = stack([title, aboutLabel("版本 \(version)（\(build)）"), aboutLabel("硬件架构：arm64"), aboutLabel("系统信息：\(macOSVersion)"), aboutLabel("Author: houlake@gmail.com", size: 11, secondary: true), aboutLabel("© 2026 HostEditor contributors", size: 11, secondary: true), aboutLabel("保留所有权利 · 第三方组件使用 Apple 系统框架", size: 11, secondary: true)])
            content.translatesAutoresizingMaskIntoConstraints = false; about.contentView?.addSubview(content)
            NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: about.contentView!.leadingAnchor, constant: 28), content.topAnchor.constraint(equalTo: about.contentView!.topAnchor, constant: 28)])
            aboutWindow = about
        }
        applyTheme(); aboutWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc func showFind() {
        let range = editor.selectedRange()
        if range.length > 0, NSMaxRange(range) <= (editor.string as NSString).length {
            let selection = (editor.string as NSString).substring(with: range)
            let pasteboard = NSPasteboard(name: .find)
            pasteboard.clearContents()
            pasteboard.setString(selection, forType: .string)
        }
        let action = NSMenuItem()
        action.tag = NSTextFinder.Action.showFindInterface.rawValue
        editor.performFindPanelAction(action)
    }
    func showError(_ error: Error) { let alert = NSAlert(); alert.alertStyle = .warning; alert.messageText = "操作未完成"; alert.informativeText = error.localizedDescription; alert.runModal(); refreshStatus() }
    func confirm(_ title: String, detail: String, button: String) -> Bool {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail
        alert.addButton(withTitle: button); alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(saveAction) { return dirty && !busy && !conflict }
        if menuItem.action == #selector(reloadAction) || menuItem.action == #selector(showBackups) { return snapshot != nil && !busy }
        return true
    }
}

private extension NSKeyValueObservation {
    func store(in destination: inout NSKeyValueObservation?) { destination = self }
}
