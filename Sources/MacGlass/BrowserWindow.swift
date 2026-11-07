// MacGlass - shader browser (Shader > Choose from Library...).
// SPDX-License-Identifier: GPL-3.0-only
import AppKit

final class BrowserWindowController: NSWindowController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSearchFieldDelegate {
    private let library: ShaderLibrary
    private let outline = NSOutlineView()
    private let search = NSSearchField()
    private var matches: [PresetEntry] = []
    private var filtering: Bool { !search.stringValue.trimmingCharacters(in: .whitespaces).isEmpty }
    private var suppressSelection = false
    var onChoose: ((PresetEntry) -> Void)?
    var onImport: (() -> Void)?

    init(library: ShaderLibrary) {
        self.library = library
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 620),
                              styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: true)
        window.title = "Shader Library"
        window.setFrameAutosaveName("MacGlassShaderBrowser")
        super.init(window: window)
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        search.placeholderString = "Search presets"
        search.delegate = self
        search.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.title = "Preset"
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.dataSource = self
        outline.delegate = self
        outline.rowSizeStyle = .default
        outline.target = self
        outline.doubleAction = #selector(doubleClicked)
        outline.autoresizesOutlineColumn = true

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let importButton = NSButton(title: "Import custom...", target: self, action: #selector(importClicked))
        let folderButton = NSButton(title: "Open Custom_Shader Folder", target: self, action: #selector(openFolder))
        let rescanButton = NSButton(title: "Rescan", target: self, action: #selector(rescan))
        let buttons = NSStackView(views: [importButton, folderButton, rescanButton])
        buttons.orientation = .horizontal
        buttons.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(search)
        content.addSubview(scroll)
        content.addSubview(buttons)
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            search.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            search.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -8),
            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            buttons.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -10),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
        ])
    }

    func reload(selecting key: String?) {
        if filtering { updateMatches() }
        outline.reloadData()
        if let key { select(key: key) }
    }

    /// Expands the folders down to the current preset and selects it.
    func select(key: String) {
        suppressSelection = true
        defer { suppressSelection = false }
        if filtering {
            if let idx = matches.firstIndex(where: { $0.key == key }) {
                outline.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
                outline.scrollRowToVisible(idx)
            }
            return
        }
        var node = library.root
        var path: [ShaderFolder] = []
        while true {
            guard let next = node.folders.first(where: { key.hasPrefix($0.path + "/") }) else { break }
            path.append(next)
            node = next
        }
        for f in path { outline.expandItem(f) }
        if let preset = node.presets.first(where: { $0.key == key }) {
            let row = outline.row(forItem: PresetBox.box(preset))
            if row >= 0 {
                outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                outline.scrollRowToVisible(row)
            }
        }
    }

    // MARK: Actions

    @objc private func doubleClicked() {
        let item = outline.item(atRow: outline.clickedRow)
        if let folder = item as? ShaderFolder {
            if outline.isItemExpanded(folder) { outline.collapseItem(folder) } else { outline.expandItem(folder) }
        }
    }

    @objc private func importClicked() { onImport?() }

    @objc private func openFolder() {
        NSWorkspace.shared.open(library.customRoot)
    }

    @objc private func rescan() {
        library.rescan()
        reload(selecting: nil)
    }

    func controlTextDidChange(_ obj: Notification) {
        updateMatches()
        outline.reloadData()
    }

    private func updateMatches() {
        let words = search.stringValue.lowercased().split(separator: " ").map(String.init)
        matches = library.allPresets.filter { p in
            let hay = p.key.lowercased()
            return words.allSatisfy { hay.contains($0) }
        }
    }

    // MARK: NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if filtering { return item == nil ? matches.count : 0 }
        let folder = (item as? ShaderFolder) ?? library.root
        if item is PresetBox { return 0 }
        return folder.folders.count + folder.presets.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if filtering { return PresetBox.box(matches[index]) }
        let folder = (item as? ShaderFolder) ?? library.root
        if index < folder.folders.count { return folder.folders[index] }
        return PresetBox.box(folder.presets[index - folder.folders.count])
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is ShaderFolder
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = (outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? {
            let c = NSTableCellView()
            c.identifier = id
            let image = NSImageView()
            let text = NSTextField(labelWithString: "")
            text.lineBreakMode = .byTruncatingMiddle
            image.translatesAutoresizingMaskIntoConstraints = false
            text.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(image)
            c.addSubview(text)
            c.imageView = image
            c.textField = text
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                image.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16),
                image.heightAnchor.constraint(equalToConstant: 16),
                text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 5),
                text.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -2),
                text.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }()
        if let folder = item as? ShaderFolder {
            cell.textField?.stringValue = folder.name
            cell.imageView?.image = NSImage(named: NSImage.folderName)
        } else if let box = item as? PresetBox {
            cell.textField?.stringValue = filtering ? String(box.preset.key.dropLast(7)) : box.preset.label
            cell.imageView?.image = NSImage(systemSymbolName: "sparkles.tv", accessibilityDescription: nil)
                ?? NSImage(named: NSImage.multipleDocumentsName)
        }
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelection, let box = outline.item(atRow: outline.selectedRow) as? PresetBox else { return }
        onChoose?(box.preset)
    }
}

/// Reference wrapper, so NSOutlineView can track presets as items (identity is kept per key).
final class PresetBox: NSObject {
    let preset: PresetEntry
    private static var cache: [String: PresetBox] = [:]

    private init(_ p: PresetEntry) { preset = p }

    static func box(_ p: PresetEntry) -> PresetBox {
        if let b = cache[p.key], b.preset == p { return b }
        let b = PresetBox(p)
        cache[p.key] = b
        return b
    }
}
