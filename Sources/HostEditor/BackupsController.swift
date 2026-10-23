import AppKit
import HostsCore

final class BackupsController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    unowned let app: AppController
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 540), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    let table = NSTableView()
    let preview = NSTextView()
    let pathLabel = label("", size: 12, secondary: true)
    var records: [BackupRecord] = []
    var restoreButton: NSButton!
    var path = ""
    var generation = 0
    init(app: AppController) {
        self.app = app; super.init()
        window.title = "备份与恢复"; window.isReleasedWhenClosed = false; window.center(); window.minSize = NSSize(width: 580, height: 400)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("date")); column.title = "备份时间（最近 20 份）"; column.width = 680; table.addTableColumn(column)
        table.delegate = self; table.dataSource = self; table.setAccessibilityLabel("备份列表")
        let listing = NSScrollView(); listing.documentView = table; listing.hasVerticalScroller = true; listing.borderType = .bezelBorder
        preview.isEditable = false; preview.isRichText = false; preview.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        preview.textContainerInset = NSSize(width: 12, height: 12); preview.setAccessibilityLabel("备份内容预览")
        preview.minSize = .zero; preview.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        preview.frame = NSRect(x: 0, y: 0, width: 700, height: 250)
        let previewScroll = NSScrollView(); previewScroll.documentView = preview; previewScroll.hasVerticalScroller = true; previewScroll.borderType = .bezelBorder
        preview.isVerticallyResizable = true; preview.autoresizingMask = [.width]; preview.textContainer?.widthTracksTextView = true
        restoreButton = button("恢复所选备份", target: self, action: #selector(restore)); restoreButton.isEnabled = false
        let disk = button("查看当前磁盘版本", target: self, action: #selector(showDisk))
        let content = stack([pathLabel, listing, label("内容预览", size: 12), previewScroll, stack([disk, NSView(), restoreButton], orientation: .horizontal)], spacing: 12)
        content.translatesAutoresizingMaskIntoConstraints = false; window.contentView!.addSubview(content)
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 20), content.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -20),
            content.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 20), content.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -20), listing.heightAnchor.constraint(equalToConstant: 150), previewScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 100)])
        for view in content.arrangedSubviews { view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
    }
    func show() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    func load(path: String) {
        self.path = path; generation += 1; let current = generation
        pathLabel.stringValue = path; records = []; preview.string = "正在读取备份"; restoreButton.isEnabled = false; table.reloadData()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try BackupStore.user.list(path: path) }
            DispatchQueue.main.async {
                guard current == self.generation else { return }
                switch result {
                case .success(let records): self.records = records; self.table.reloadData(); self.preview.string = records.isEmpty ? "暂无备份。每次覆盖保存前会创建旧版本备份。" : "选择备份查看内容。"
                case .failure(let error): self.preview.string = error.localizedDescription
                }
            }
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { records.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let record = records[row]
        return label(DateFormatter.localizedString(from: record.date, dateStyle: .medium, timeStyle: .medium) + "  ·  \(record.snapshot.data.count) 字节", size: 12)
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow; restoreButton.isEnabled = records.indices.contains(row)
        if records.indices.contains(row) { preview.string = records[row].snapshot.text }
    }
    @objc func restore() { if records.indices.contains(table.selectedRow) { app.restore(records[table.selectedRow]) } }
    @objc func showDisk() {
        guard !path.isEmpty else { return }
        let candidate = path
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try FileStore.load(candidate) }
            DispatchQueue.main.async {
                guard candidate == self.path else { return }
                self.table.deselectAll(nil); self.restoreButton.isEnabled = false
                switch result { case .success(let value): self.preview.string = value.text; case .failure(let error): self.preview.string = error.localizedDescription }
            }
        }
    }
}
