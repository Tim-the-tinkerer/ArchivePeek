import AppKit
import QuickLookUI
import SwiftUI
import UniformTypeIdentifiers

struct ArchiveEntryTableView: NSViewRepresentable {
    let entries: [ArchiveEntry]
    @Binding var selection: Set<String>
    let onOpenEntry: (ArchiveEntry) -> Void
    let onPreviewEntry: (ArchiveEntry) -> Void
    let onExtractEntry: (ArchiveEntry) -> Void
    let onOpenSelected: () -> Void
    let onExtractSelected: () -> Void
    let onQuickLookSelected: () -> Void
    let onPrepareDragOut: (ArchiveEntry) -> Void
    let preparedDragURL: (ArchiveEntry) -> URL?
    let writeDraggedEntry: (ArchiveEntry, URL, @escaping (Error?) -> Void) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let tableView = EntryTableView()
        tableView.style = .fullWidth
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.rowHeight = 22
        tableView.intercellSpacing = NSSize(width: 8, height: 4)
        tableView.doubleAction = #selector(Coordinator.handleDoubleClick(_:))
        tableView.target = context.coordinator
        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator
        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)
        tableView.setDraggingSourceOperationMask(.copy, forLocal: true)
        bindInteractionHandlers(to: tableView, coordinator: context.coordinator)

        addColumn("name", title: "Name", width: 280, minWidth: 180, to: tableView)
        addColumn("size", title: "Size", width: 80, minWidth: 64, to: tableView)
        addColumn("compressed", title: "Compressed", width: 90, minWidth: 72, to: tableView)
        addColumn("modified", title: "Modified", width: 130, minWidth: 110, to: tableView)
        addColumn("path", title: "Path", width: 220, minWidth: 120, to: tableView)

        scrollView.documentView = tableView
        context.coordinator.tableView = tableView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self

        guard let tableView = scrollView.documentView as? EntryTableView else { return }
        bindInteractionHandlers(to: tableView, coordinator: coordinator)

        let entryPaths = entries.map(\.path)
        let contentChanged = coordinator.lastEntryPaths != entryPaths
        if contentChanged {
            coordinator.lastEntryPaths = entryPaths
            tableView.reloadData()
            // Focus only when the listed content changes (navigate / open archive),
            // not on every SwiftUI refresh — that steals focus from other controls.
            if !entries.isEmpty {
                DispatchQueue.main.async {
                    tableView.window?.makeFirstResponder(tableView)
                }
            }
        }

        if !coordinator.isUpdatingSelection {
            coordinator.syncSelectionToTable()
        }
    }

    private func bindInteractionHandlers(to tableView: EntryTableView, coordinator: Coordinator) {
        tableView.onReturn = { [weak coordinator] in
            coordinator?.parent.onOpenSelected()
        }
        tableView.onSpacePreview = { [weak coordinator] in
            coordinator?.handleSpacePreview()
        }
    }

    private func addColumn(
        _ identifier: String,
        title: String,
        width: CGFloat,
        minWidth: CGFloat,
        to tableView: NSTableView
    ) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
        column.title = title
        column.width = width
        column.minWidth = minWidth
        tableView.addTableColumn(column)
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: ArchiveEntryTableView
        weak var tableView: NSTableView?
        var lastEntryPaths: [String] = []
        var isUpdatingSelection = false
        private var dragDelegates: [String: ArchiveEntryDragDelegate] = [:]

        init(parent: ArchiveEntryTableView) {
            self.parent = parent
        }

        var entries: [ArchiveEntry] { parent.entries }

        func entry(at row: Int) -> ArchiveEntry? {
            guard row >= 0, row < entries.count else { return nil }
            return entries[row]
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            entries.count
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row >= 0, row < entries.count, let tableColumn else { return nil }
            let entry = entries[row]
            let identifier = tableColumn.identifier

            switch identifier.rawValue {
            case "name":
                return nameCell(for: entry, in: tableView, column: tableColumn)
            case "size":
                return textCell(
                    EntryFormatting.sizeLabel(for: entry),
                    in: tableView,
                    identifier: "SizeCell",
                    monospaced: true,
                    secondary: true
                )
            case "compressed":
                return textCell(
                    EntryFormatting.compressedLabel(for: entry),
                    in: tableView,
                    identifier: "CompressedCell",
                    monospaced: true,
                    secondary: true
                )
            case "modified":
                return textCell(
                    EntryFormatting.modifiedLabel(for: entry),
                    in: tableView,
                    identifier: "ModifiedCell",
                    monospaced: false,
                    secondary: true
                )
            case "path":
                return textCell(
                    entry.path,
                    in: tableView,
                    identifier: "PathCell",
                    monospaced: false,
                    secondary: true,
                    font: .systemFont(ofSize: NSFont.smallSystemFontSize)
                )
            default:
                return nil
            }
        }

        private func nameCell(for entry: ArchiveEntry, in tableView: NSTableView, column: NSTableColumn) -> NSView {
            let identifier = NSUserInterfaceItemIdentifier("NameCell")
            let cell = (tableView.makeView(withIdentifier: identifier, owner: nil) as? ArchiveTableCellView) ?? {
                let view = ArchiveTableCellView()
                view.identifier = identifier

                let imageView = NSImageView()
                imageView.translatesAutoresizingMaskIntoConstraints = false
                imageView.imageScaling = .scaleProportionallyDown
                view.addSubview(imageView)

                let textField = NSTextField(labelWithString: "")
                configureNonInteractive(textField)
                textField.translatesAutoresizingMaskIntoConstraints = false
                textField.lineBreakMode = .byTruncatingTail
                view.addSubview(textField)

                NSLayoutConstraint.activate([
                    imageView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 2),
                    imageView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                    imageView.widthAnchor.constraint(equalToConstant: 16),
                    imageView.heightAnchor.constraint(equalToConstant: 16),
                    textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 8),
                    textField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
                    textField.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                ])

                view.imageView = imageView
                view.textField = textField
                return view
            }()

            let symbol = entry.isDirectory ? "folder.fill" : EntryFormatting.iconName(for: entry)
            cell.imageView?.image = NSImage(
                systemSymbolName: symbol,
                accessibilityDescription: nil
            )
            cell.imageView?.contentTintColor = entry.isDirectory ? .controlAccentColor : .secondaryLabelColor
            cell.textField?.stringValue = entry.displayName
            return cell
        }

        private func textCell(
            _ value: String,
            in tableView: NSTableView,
            identifier: String,
            monospaced: Bool,
            secondary: Bool,
            font: NSFont? = nil
        ) -> NSView {
            let cellID = NSUserInterfaceItemIdentifier(identifier)
            let cell = (tableView.makeView(withIdentifier: cellID, owner: nil) as? ArchiveTableCellView) ?? {
                let view = ArchiveTableCellView()
                view.identifier = cellID
                let textField = NSTextField(labelWithString: "")
                configureNonInteractive(textField)
                textField.translatesAutoresizingMaskIntoConstraints = false
                textField.lineBreakMode = .byTruncatingMiddle
                view.addSubview(textField)
                NSLayoutConstraint.activate([
                    textField.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                    textField.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                    textField.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                ])
                view.textField = textField
                return view
            }()

            if let font {
                cell.textField?.font = font
            } else if monospaced {
                cell.textField?.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            } else {
                cell.textField?.font = .systemFont(ofSize: NSFont.systemFontSize)
            }
            cell.textField?.textColor = secondary ? .secondaryLabelColor : .labelColor
            cell.textField?.stringValue = value
            return cell
        }

        private func configureNonInteractive(_ textField: NSTextField) {
            textField.isEditable = false
            textField.isSelectable = false
            textField.refusesFirstResponder = true
            textField.isBordered = false
            textField.drawsBackground = false
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let tableView = notification.object as? NSTableView else { return }
            isUpdatingSelection = true
            defer { isUpdatingSelection = false }

            var newSelection = Set<String>()
            for row in tableView.selectedRowIndexes {
                guard row >= 0, row < entries.count else { continue }
                newSelection.insert(entries[row].path)
            }
            if newSelection != parent.selection {
                parent.selection = newSelection
            }

            for row in tableView.selectedRowIndexes where row >= 0 && row < entries.count {
                parent.onPrepareDragOut(entries[row])
            }
        }

        func syncSelectionToTable() {
            guard let tableView else { return }
            var indexes = IndexSet()
            for (index, entry) in entries.enumerated() where parent.selection.contains(entry.path) {
                indexes.insert(index)
            }
            if tableView.selectedRowIndexes != indexes {
                tableView.selectRowIndexes(indexes, byExtendingSelection: false)
            }
        }

        @objc func handleDoubleClick(_ sender: Any?) {
            guard let tableView, tableView.clickedRow >= 0 else { return }
            let row = tableView.clickedRow
            guard row < entries.count else { return }
            parent.onOpenEntry(entries[row])
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard row >= 0, row < entries.count else { return nil }
            let entry = entries[row]

            parent.onPrepareDragOut(entry)

            if let url = Self.waitForPreparedURL(entry: entry, provider: parent.preparedDragURL) {
                return url as NSURL
            }

            if dragDelegates.count > 32 {
                dragDelegates.removeAll()
            }
            let delegate = ArchiveEntryDragDelegate(entry: entry) { [weak self] entry, url, completion in
                self?.parent.writeDraggedEntry(entry, url, completion)
            }
            dragDelegates[entry.path] = delegate
            return NSFilePromiseProvider(fileType: Self.promisedFileType(for: entry), delegate: delegate)
        }

        func tableView(
            _ tableView: NSTableView,
            draggingSession: NSDraggingSession,
            willBeginAt draggedImageLocation: NSPoint,
            forRowIndexes rowIndexes: IndexSet
        ) {
            for row in rowIndexes where row >= 0 && row < entries.count {
                parent.onPrepareDragOut(entries[row])
            }
        }

        func tableView(
            _ tableView: NSTableView,
            draggingSession: NSDraggingSession,
            sourceOperationMaskFor context: NSDraggingContext
        ) -> NSDragOperation {
            .copy
        }

        private static func promisedFileType(for entry: ArchiveEntry) -> String {
            if entry.isDirectory {
                return UTType.folder.identifier
            }
            let ext = (entry.displayName as NSString).pathExtension.lowercased()
            if !ext.isEmpty, let type = UTType(filenameExtension: ext) {
                return type.identifier
            }
            return UTType.data.identifier
        }

        private static func waitForPreparedURL(
            entry: ArchiveEntry,
            provider: (ArchiveEntry) -> URL?,
            timeout: TimeInterval = 0.35
        ) -> URL? {
            // Brief wait only — pasteboardWriter runs on the main thread. Longer spins freeze the UI;
            // fall through to NSFilePromiseProvider for slow extracts.
            if let url = provider(entry) {
                return url
            }
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if let url = provider(entry) {
                    return url
                }
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
            return provider(entry)
        }

        func tableView(_ tableView: NSTableView, menuFor tableColumn: NSTableColumn?, row: Int) -> NSMenu? {
            if row >= 0, row < entries.count {
                return rowMenu(for: entries[row])
            }
            guard !parent.selection.isEmpty else { return nil }
            return selectionMenu()
        }

        private func rowMenu(for entry: ArchiveEntry) -> NSMenu {
            let menu = NSMenu()

            let openItem = menu.addItem(withTitle: "Open", action: #selector(openRow(_:)), keyEquivalent: "")
            openItem.target = self
            openItem.representedObject = entry

            if !entry.isDirectory {
                let previewItem = menu.addItem(withTitle: "Quick Look", action: #selector(previewRow(_:)), keyEquivalent: "")
                previewItem.target = self
                previewItem.representedObject = entry
                let extractItem = menu.addItem(withTitle: "Extract…", action: #selector(extractRow(_:)), keyEquivalent: "")
                extractItem.target = self
                extractItem.representedObject = entry
            }
            return menu
        }

        private func selectionMenu() -> NSMenu {
            let menu = NSMenu()
            let openItem = menu.addItem(withTitle: "Open", action: #selector(openSelected(_:)), keyEquivalent: "")
            openItem.target = self
            let extractItem = menu.addItem(withTitle: "Extract Selected", action: #selector(extractSelected(_:)), keyEquivalent: "")
            extractItem.target = self
            let previewItem = menu.addItem(withTitle: "Quick Look", action: #selector(quickLookSelected(_:)), keyEquivalent: "")
            previewItem.target = self
            return menu
        }

        @objc private func openRow(_ sender: NSMenuItem) {
            guard let entry = sender.representedObject as? ArchiveEntry else { return }
            parent.onOpenEntry(entry)
        }

        @objc private func previewRow(_ sender: NSMenuItem) {
            guard let entry = sender.representedObject as? ArchiveEntry else { return }
            parent.onPreviewEntry(entry)
        }

        @objc private func extractRow(_ sender: NSMenuItem) {
            guard let entry = sender.representedObject as? ArchiveEntry else { return }
            parent.onExtractEntry(entry)
        }

        @objc private func openSelected(_ sender: NSMenuItem) {
            parent.onOpenSelected()
        }

        @objc private func extractSelected(_ sender: NSMenuItem) {
            parent.onExtractSelected()
        }

        @objc private func quickLookSelected(_ sender: NSMenuItem) {
            parent.onQuickLookSelected()
        }

        func handleSpacePreview() {
            if let panel = QLPreviewPanel.shared(), panel.isVisible {
                panel.orderOut(nil)
                QuickLookCoordinator.shared.previewURL = nil
                return
            }
            parent.onQuickLookSelected()
        }
    }
}

private final class ArchiveTableCellView: NSTableCellView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        enclosingTableView?.window?.makeFirstResponder(enclosingTableView)
        super.mouseDown(with: event)
    }

    private var enclosingTableView: NSTableView? {
        var view: NSView? = self
        while let current = view {
            if let table = current as? NSTableView {
                return table
            }
            view = current.superview
        }
        return nil
    }
}

private final class EntryTableView: NSTableView {
    var onReturn: (() -> Void)?
    var onSpacePreview: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if handlePreviewShortcut(event) { return }
        if event.keyCode == 36 || event.keyCode == 76 {
            onReturn?()
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handlePreviewShortcut(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    @objc override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        false
    }

    private func handlePreviewShortcut(_ event: NSEvent) -> Bool {
        guard event.keyCode == 49 else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.isEmpty || modifiers == [.capsLock] else { return false }
        onSpacePreview?()
        return true
    }
}

private final class ArchiveEntryDragDelegate: NSObject, NSFilePromiseProviderDelegate {
    let entry: ArchiveEntry
    let onWrite: (ArchiveEntry, URL, @escaping (Error?) -> Void) -> Void

    init(entry: ArchiveEntry, onWrite: @escaping (ArchiveEntry, URL, @escaping (Error?) -> Void) -> Void) {
        self.entry = entry
        self.onWrite = onWrite
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        entry.displayName
    }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let destination = url.appendingPathComponent(entry.displayName)
        onWrite(entry, destination, completionHandler)
    }
}

private enum EntryFormatting {
    static func iconName(for entry: ArchiveEntry) -> String {
        let ext = (entry.displayName as NSString).pathExtension.lowercased()
        switch ext {
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp":
            return "photo"
        case "mp3", "m4a", "wav", "flac", "aac", "ogg":
            return "music.note"
        case "mp4", "mov", "mkv", "avi", "webm":
            return "film"
        case "pdf":
            return "doc.richtext"
        case "txt", "md", "json", "xml", "html", "css", "js", "swift":
            return "doc.text"
        case "zip", "7z", "rar", "tar", "gz":
            return "doc.zipper"
        default:
            return "doc"
        }
    }

    static func sizeLabel(for entry: ArchiveEntry) -> String {
        guard !entry.isDirectory else { return "—" }
        return ByteCountFormatter.string(fromByteCount: entry.uncompressedSize, countStyle: .file)
    }

    static func compressedLabel(for entry: ArchiveEntry) -> String {
        guard !entry.isDirectory, let compressed = entry.compressedSize else { return "—" }
        return ByteCountFormatter.string(fromByteCount: compressed, countStyle: .file)
    }

    static func modifiedLabel(for entry: ArchiveEntry) -> String {
        guard let modified = entry.modified else { return "—" }
        return modified.formatted(date: .abbreviated, time: .shortened)
    }
}