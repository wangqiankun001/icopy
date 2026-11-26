import AppKit

final class HistoryPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    var commandPHandler: (() -> Bool)?
    var closeHandler: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command),
           !flags.contains(.option),
           !flags.contains(.control) {
            let key = event.charactersIgnoringModifiers?.lowercased()
            if key == "p", commandPHandler?() == true {
                return true
            }
            if key == "w" {
                closeHandler?()
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

final class HistoryPanelController: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let store: ClipboardStore
    private let panel: HistoryPanel
    private let background: NSVisualEffectView
    private let titleLabel: NSTextField
    private let countLabel: NSTextField
    private let shortcutLabel: NSTextField
    private let searchField: NSSearchField
    private let scrollView: NSScrollView
    private let tableView: NSTableView
    private let emptyView: EmptyStateView
    private let footerLabel: NSTextField

    private var rows: [ClipItem] = []

    var onChoose: ((ClipItem) -> Void)?
    var onCancel: (() -> Void)?

    var isVisible: Bool { panel.isVisible }

    private let panelWidth: CGFloat = 480
    private let tableWidth: CGFloat = 468
    private let maxTableHeight: CGFloat = 428

    override init() {
        fatalError("Use init(store:)")
    }

    init(store: ClipboardStore) {
        self.store = store

        panel = HistoryPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        background = NSVisualEffectView()
        titleLabel = NSTextField(labelWithString: "剪贴板历史")
        countLabel = NSTextField(labelWithString: "0 项")
        shortcutLabel = NSTextField(labelWithString: "⌘⇧V")
        searchField = NSSearchField()
        scrollView = NSScrollView()
        tableView = NSTableView()
        emptyView = EmptyStateView()
        footerLabel = NSTextField(labelWithString: "↑↓ 选择    ⏎ 粘贴    ⌘P 固定    ⌫ 删除    esc 关闭")

        super.init()

        buildPanel()
        buildContent()
        panel.delegate = self
        panel.commandPHandler = { [weak self] in
            self?.togglePinSelected() ?? false
        }
        panel.closeHandler = { [weak self] in
            self?.cancel()
        }

        store.onChange = { [weak self] in
            self?.storeDidChange()
        }
    }

    // MARK: - Public

    func show() {
        guard !panel.isVisible else { return }

        searchField.stringValue = ""
        rebuildRows(selectingID: nil)
        updatePanelSize()
        positionPanel()

        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)

        if !rows.isEmpty {
            selectRow(0, scroll: false)
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        panel.orderOut(nil)
    }

    func snapshot(to url: URL) {
        guard let view = panel.contentView else { return }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }

        NSGraphicsContext.saveGraphicsState()
        if let context = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = context
            NSColor.windowBackgroundColor.setFill()
            view.bounds.fill()
        }
        NSGraphicsContext.restoreGraphicsState()

        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url)

        let diagnostics = """
        key=\(panel.isKeyWindow)
        visible=\(panel.isVisible)
        appActive=\(NSApp.isActive)
        firstResponder=\(String(describing: panel.firstResponder))
        frame=\(panel.frame)
        rows=\(rows.count)
        """
        let diagURL = url.deletingPathExtension().appendingPathExtension("txt")
        try? diagnostics.write(to: diagURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Panel construction

    private func buildPanel() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.animationBehavior = .none

        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 16
        background.layer?.masksToBounds = true
        background.autoresizingMask = [.width, .height]
        panel.contentView = background
    }

    private func buildContent() {
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        countLabel.translatesAutoresizingMaskIntoConstraints = false

        shortcutLabel.font = .monospacedSystemFont(ofSize: 10.5, weight: .medium)
        shortcutLabel.textColor = .tertiaryLabelColor
        shortcutLabel.translatesAutoresizingMaskIntoConstraints = false

        searchField.placeholderString = "搜索剪贴板历史"
        searchField.font = .systemFont(ofSize: 12.5)
        searchField.focusRingType = .none
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        column.width = tableWidth
        column.minWidth = 240
        column.resizingMask = .autoresizingMask

        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 68
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.allowsEmptySelection = false
        tableView.allowsMultipleSelection = false
        tableView.focusRingType = .none
        tableView.style = .plain
        tableView.gridStyleMask = []
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(tableClicked(_:))
        tableView.frame = NSRect(x: 0, y: 0, width: tableWidth, height: 1)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.verticalScrollElasticity = .allowed
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        footerLabel.font = .systemFont(ofSize: 10.5)
        footerLabel.textColor = .tertiaryLabelColor
        footerLabel.alignment = .center
        footerLabel.translatesAutoresizingMaskIntoConstraints = false

        emptyView.translatesAutoresizingMaskIntoConstraints = false

        background.addSubview(titleLabel)
        background.addSubview(countLabel)
        background.addSubview(shortcutLabel)
        background.addSubview(searchField)
        background.addSubview(scrollView)
        background.addSubview(emptyView)
        background.addSubview(footerLabel)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: background.topAnchor, constant: 14),
            titleLabel.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 16),

            countLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            countLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 8),
            countLabel.trailingAnchor.constraint(lessThanOrEqualTo: shortcutLabel.leadingAnchor, constant: -8),

            shortcutLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            shortcutLabel.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -16),

            searchField.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            searchField.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -12),
            searchField.heightAnchor.constraint(equalToConstant: 30),

            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 6),
            scrollView.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -6),
            scrollView.bottomAnchor.constraint(equalTo: footerLabel.topAnchor, constant: -6),

            emptyView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            emptyView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            emptyView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            emptyView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),

            footerLabel.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 12),
            footerLabel.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -12),
            footerLabel.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -8),
            footerLabel.heightAnchor.constraint(equalToConstant: 16)
        ])

        updateEmptyState()
    }

    // MARK: - Sizing

    private func rowHeight(for item: ClipItem) -> CGFloat {
        item.kind == .image ? 92 : 68
    }

    private var desiredTableHeight: CGFloat {
        guard !rows.isEmpty else { return 190 }
        let content = rows.reduce(CGFloat(0)) { partial, item in
            partial + rowHeight(for: item) + tableView.intercellSpacing.height
        }
        return min(max(content + 4, 150), maxTableHeight)
    }

    private func updatePanelSize() {
        let height = 106 + desiredTableHeight
        if panel.isVisible {
            let top = panel.frame.maxY
            panel.setFrame(
                NSRect(x: panel.frame.minX, y: top - height, width: panelWidth, height: height),
                display: true
            )
        } else {
            panel.setContentSize(NSSize(width: panelWidth, height: height))
        }
    }

    private func positionPanel() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let height = panel.frame.height
        let x = floor(visible.midX - panelWidth / 2)
        let y = floor(visible.maxY - height - 14)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func updateTableFrame() {
        let content = rows.reduce(CGFloat(0)) { partial, item in
            partial + rowHeight(for: item) + tableView.intercellSpacing.height
        }
        let height = max(content + 4, 1)
        tableView.frame = NSRect(x: 0, y: 0, width: tableWidth, height: height)
    }

    // MARK: - Rows

    private func rebuildRows(selectingID: UUID?) {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            rows = store.items
        } else {
            rows = store.items.filter { $0.searchableText.localizedCaseInsensitiveContains(query) }
        }

        tableView.reloadData()
        updateTableFrame()
        updateCountLabel()
        updateEmptyState()
        updatePanelSize()

        if let selectingID, let index = rows.firstIndex(where: { $0.id == selectingID }) {
            selectRow(index, scroll: true)
        } else if !rows.isEmpty {
            selectRow(0, scroll: true)
        } else {
            tableView.deselectAll(nil)
        }
        refreshRowSelection()
    }

    private func storeDidChange() {
        guard panel.isVisible else { return }
        let selected = selectedItem?.id
        rebuildRows(selectingID: selected)
    }

    private func updateCountLabel() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            countLabel.stringValue = "\(store.items.count) 项"
        } else {
            countLabel.stringValue = "\(rows.count) / \(store.items.count) 项"
        }
    }

    private func updateEmptyState() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        emptyView.isHidden = !rows.isEmpty
        if rows.isEmpty {
            emptyView.configure(hasQuery: !query.isEmpty)
        }
    }

    private func selectRow(_ index: Int, scroll: Bool) {
        guard index >= 0, index < rows.count else { return }
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        if scroll {
            tableView.scrollRowToVisible(index)
        }
        refreshRowSelection()
    }

    private func refreshRowSelection() {
        tableView.enumerateAvailableRowViews { rowView, _ in
            rowView.needsDisplay = true
        }
    }

    private var selectedItem: ClipItem? {
        let row = tableView.selectedRow
        guard row >= 0, row < rows.count else { return nil }
        return rows[row]
    }

    private func moveSelection(by delta: Int) {
        guard !rows.isEmpty else { return }
        let current = tableView.selectedRow
        let next: Int
        if current < 0 {
            next = delta > 0 ? 0 : rows.count - 1
        } else {
            next = min(max(current + delta, 0), rows.count - 1)
        }
        selectRow(next, scroll: true)
    }

    private func togglePinSelected() -> Bool {
        guard let item = selectedItem else { return false }
        store.togglePin(item.id)
        return true
    }

    private func deleteSelected() -> Bool {
        guard let item = selectedItem else { return false }
        store.delete(item.id)
        return true
    }

    private func chooseSelected() {
        guard let item = selectedItem else { return }
        onChoose?(item)
    }

    private func cancel() {
        hide()
        onCancel?()
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row < rows.count else { return 68 }
        return rowHeight(for: rows[row])
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count else { return nil }
        let item = rows[row]
        let identifier = NSUserInterfaceItemIdentifier("HistoryCell")
        let cell: HistoryCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? HistoryCellView {
            cell = reused
        } else {
            cell = HistoryCellView()
            cell.identifier = identifier
        }

        cell.configure(
            item: item,
            image: store.image(for: item),
            onPin: { [weak self] in
                self?.store.togglePin(item.id)
            },
            onDelete: { [weak self] in
                self?.store.delete(item.id)
            }
        )
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        HistoryRowView()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        refreshRowSelection()
    }

    @objc private func tableClicked(_ sender: NSTableView) {
        let row = sender.clickedRow
        guard row >= 0, row < rows.count else { return }
        onChoose?(rows[row])
    }

    // MARK: - Search field

    func controlTextDidChange(_ obj: Notification) {
        guard panel.isVisible else { return }
        rebuildRows(selectingID: nil)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
            return true
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            chooseSelected()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancel()
            return true
        case #selector(NSResponder.deleteBackward(_:)):
            if searchField.stringValue.isEmpty {
                return deleteSelected()
            }
            return false
        default:
            return false
        }
    }

    // MARK: - Window delegate

    func windowDidResignKey(_ notification: Notification) {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
    }
}

// MARK: - Row

final class HistoryRowView: NSTableRowView {
    private var hovering = false {
        didSet { needsDisplay = true }
    }
    private var trackingArea: NSTrackingArea?

    override func drawBackground(in dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 6, dy: 2)
        guard rect.width > 0, rect.height > 0 else { return }

        if isSelected {
            NSColor.controlAccentColor.withAlphaComponent(0.17).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9).fill()
        } else if hovering {
            NSColor.labelColor.withAlphaComponent(0.05).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9).fill()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
    }
}

// MARK: - Cell

final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class HistoryCellView: NSTableCellView {
    private let badge = PassthroughView()
    private let thumbnailView = NSImageView()
    private let symbolView = NSImageView()
    private let textContainer = PassthroughView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let pinButton = NSButton()
    private let deleteButton = NSButton()
    private var badgeWidthConstraint: NSLayoutConstraint!
    private var badgeHeightConstraint: NSLayoutConstraint!

    private var onPin: (() -> Void)?
    private var onDelete: (() -> Void)?
    private var isPinned = false
    private var hovering = false {
        didSet { updateButtonVisibility() }
    }
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        build()
    }

    func configure(
        item: ClipItem,
        image: NSImage?,
        onPin: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.onPin = onPin
        self.onDelete = onDelete
        isPinned = item.pinned

        titleLabel.stringValue = item.titleText.isEmpty ? "空内容" : item.titleText
        subtitleLabel.stringValue = item.detailText

        let isImage = item.kind == .image && image != nil
        thumbnailView.isHidden = !isImage
        symbolView.isHidden = isImage
        badgeWidthConstraint.constant = isImage ? 64 : 48
        badgeHeightConstraint.constant = isImage ? 64 : 48
        badge.layer?.cornerRadius = isImage ? 11 : 10
        badge.layer?.borderWidth = isImage ? 0.5 : 0
        badge.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.7).cgColor
        thumbnailView.image = image

        if !isImage {
            switch item.kind {
            case .text:
                badge.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.13).cgColor
                symbolView.contentTintColor = .systemBlue
                symbolView.image = NSImage(
                    systemSymbolName: "text.quote",
                    accessibilityDescription: nil
                )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 19, weight: .medium))
            case .files:
                badge.layer?.backgroundColor = NSColor.systemTeal.withAlphaComponent(0.14).cgColor
                symbolView.contentTintColor = .systemTeal
                symbolView.image = NSImage(
                    systemSymbolName: "doc.fill",
                    accessibilityDescription: nil
                )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 19, weight: .medium))
            case .image:
                badge.layer?.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.08).cgColor
                symbolView.contentTintColor = .secondaryLabelColor
                symbolView.image = NSImage(
                    systemSymbolName: "photo",
                    accessibilityDescription: nil
                )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 19, weight: .medium))
            }
        }

        pinButton.image = NSImage(
            systemSymbolName: item.pinned ? "pin.fill" : "pin",
            accessibilityDescription: "固定"
        )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11.5, weight: .medium))
        pinButton.contentTintColor = item.pinned ? .controlAccentColor : .secondaryLabelColor

        hovering = false
        updateButtonVisibility()
    }

    private func build() {
        wantsLayer = true

        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 10
        badge.layer?.masksToBounds = true
        badge.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.13).cgColor
        addSubview(badge)

        thumbnailView.translatesAutoresizingMaskIntoConstraints = false
        thumbnailView.imageScaling = .scaleProportionallyUpOrDown
        thumbnailView.isHidden = true
        badge.addSubview(thumbnailView)

        symbolView.translatesAutoresizingMaskIntoConstraints = false
        symbolView.imageScaling = .scaleProportionallyDown
        badge.addSubview(symbolView)

        textContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textContainer)

        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.textColor = .labelColor
        titleLabel.maximumNumberOfLines = 2
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.cell?.usesSingleLineMode = false
        titleLabel.cell?.wraps = true
        titleLabel.cell?.isScrollable = false
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        textContainer.addSubview(titleLabel)

        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        textContainer.addSubview(subtitleLabel)

        configureButton(pinButton, symbol: "pin", tooltip: "固定", action: #selector(pinTapped))
        configureButton(deleteButton, symbol: "trash", tooltip: "删除", action: #selector(deleteTapped))
        addSubview(pinButton)
        addSubview(deleteButton)

        badgeWidthConstraint = badge.widthAnchor.constraint(equalToConstant: 48)
        badgeHeightConstraint = badge.heightAnchor.constraint(equalToConstant: 48)

        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            badgeWidthConstraint,
            badgeHeightConstraint,

            thumbnailView.leadingAnchor.constraint(equalTo: badge.leadingAnchor),
            thumbnailView.trailingAnchor.constraint(equalTo: badge.trailingAnchor),
            thumbnailView.topAnchor.constraint(equalTo: badge.topAnchor),
            thumbnailView.bottomAnchor.constraint(equalTo: badge.bottomAnchor),

            symbolView.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            symbolView.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            symbolView.widthAnchor.constraint(equalToConstant: 26),
            symbolView.heightAnchor.constraint(equalToConstant: 26),

            pinButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            pinButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            pinButton.widthAnchor.constraint(equalToConstant: 22),
            pinButton.heightAnchor.constraint(equalToConstant: 22),

            deleteButton.trailingAnchor.constraint(equalTo: pinButton.leadingAnchor, constant: -2),
            deleteButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            deleteButton.widthAnchor.constraint(equalToConstant: 22),
            deleteButton.heightAnchor.constraint(equalToConstant: 22),

            textContainer.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 10),
            textContainer.trailingAnchor.constraint(equalTo: deleteButton.leadingAnchor, constant: -8),
            textContainer.centerYAnchor.constraint(equalTo: centerYAnchor),
            textContainer.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 6),
            textContainer.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -6),

            titleLabel.topAnchor.constraint(equalTo: textContainer.topAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: textContainer.leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: textContainer.trailingAnchor),
            titleLabel.heightAnchor.constraint(lessThanOrEqualToConstant: 34),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),
            subtitleLabel.leadingAnchor.constraint(equalTo: textContainer.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: textContainer.trailingAnchor),
            subtitleLabel.bottomAnchor.constraint(equalTo: textContainer.bottomAnchor)
        ])

        updateButtonVisibility()
    }

    private func configureButton(_ button: NSButton, symbol: String, tooltip: String, action: Selector) {
        button.isBordered = false
        button.bezelStyle = .shadowlessSquare
        button.imagePosition = .imageOnly
        button.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: tooltip
        )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11.5, weight: .medium))
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = tooltip
        button.target = self
        button.action = action
        button.refusesFirstResponder = true
        button.translatesAutoresizingMaskIntoConstraints = false
    }

    private func updateButtonVisibility() {
        pinButton.isHidden = !(isPinned || hovering)
        deleteButton.isHidden = !hovering
    }

    @objc private func pinTapped() {
        onPin?()
    }

    @objc private func deleteTapped() {
        onDelete?()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
    }
}

// MARK: - Empty state

final class EmptyStateView: NSView {
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(wrappingLabelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        build()
    }

    private func build() {
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        iconView.contentTintColor = .tertiaryLabelColor

        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.alignment = .center

        subtitleLabel.font = .systemFont(ofSize: 11.5)
        subtitleLabel.textColor = .tertiaryLabelColor
        subtitleLabel.alignment = .center
        subtitleLabel.maximumNumberOfLines = 3

        let stack = NSStackView(views: [iconView, titleLabel, subtitleLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 30),
            iconView.heightAnchor.constraint(equalToConstant: 30),
            subtitleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 330),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20)
        ])
    }

    func configure(hasQuery: Bool) {
        let config = NSImage.SymbolConfiguration(pointSize: 28, weight: .light)
        if hasQuery {
            iconView.image = NSImage(
                systemSymbolName: "magnifyingglass",
                accessibilityDescription: nil
            )?.withSymbolConfiguration(config)
            titleLabel.stringValue = "没有找到结果"
            subtitleLabel.stringValue = "换个关键词试试"
        } else {
            iconView.image = NSImage(
                systemSymbolName: "doc.on.clipboard",
                accessibilityDescription: nil
            )?.withSymbolConfiguration(config)
            titleLabel.stringValue = "暂无剪贴板历史"
            subtitleLabel.stringValue = "复制文字、图片或文件后会自动保存\n按 ⌘⇧V 随时打开"
        }
    }
}
