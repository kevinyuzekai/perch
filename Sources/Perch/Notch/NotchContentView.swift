import AppKit

enum NotchZoneKind {
    case airDrop
    case staging

    var title: String {
        switch self {
        case .airDrop: return "AirDrop"
        case .staging: return "暂存"
        }
    }

    var symbolCandidates: [String] {
        switch self {
        case .airDrop: return ["airdrop", "dot.radiowaves.left.and.right", "antenna.radiowaves.left.and.right"]
        case .staging: return ["tray.and.arrow.down.fill", "tray.full.fill", "archivebox.fill"]
        }
    }

    var tint: NSColor {
        switch self {
        case .airDrop: return NSColor(srgbRed: 0.36, green: 0.65, blue: 1.0, alpha: 1.0)
        case .staging: return NSColor(srgbRed: 0.85, green: 0.86, blue: 0.92, alpha: 1.0)
        }
    }

    static func symbol(for kind: NotchZoneKind, pointSize: CGFloat) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        for name in kind.symbolCandidates {
            if let image = NSImage(systemSymbolName: name, accessibilityDescription: kind.title) {
                return image.withSymbolConfiguration(config) ?? image
            }
        }
        return NSImage(systemSymbolName: "circle.dashed", accessibilityDescription: kind.title)
    }
}

// MARK: - 投放区

final class NotchDropZoneView: NSView {
    let kind: NotchZoneKind
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var highlighted = false

    init(kind: NotchZoneKind) {
        self.kind = kind
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 18
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        iconView.image = NotchZoneKind.symbol(for: kind, pointSize: 22)
        iconView.contentTintColor = kind.tint
        iconView.imageScaling = .scaleProportionallyUpOrDown

        label.stringValue = kind.title
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail

        addSubview(iconView)
        addSubview(label)
        refreshAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        let side: CGFloat = 24
        iconView.frame = NSRect(x: (bounds.width - side) / 2, y: bounds.midY - 2, width: side, height: side)
        label.frame = NSRect(x: 4, y: bounds.midY - 24, width: bounds.width - 8, height: 16)
    }

    func setHighlighted(_ on: Bool) {
        guard on != highlighted else { return }
        highlighted = on
        refreshAppearance()
    }

    private func refreshAppearance() {
        layer?.backgroundColor = (highlighted ? kind.tint.withAlphaComponent(0.24) : NSColor.white.withAlphaComponent(0.06)).cgColor
        layer?.borderWidth = highlighted ? 1.5 : 1
        layer?.borderColor = (highlighted ? kind.tint.withAlphaComponent(0.9) : NSColor.white.withAlphaComponent(0.12)).cgColor
        label.textColor = highlighted ? .white : NSColor.white.withAlphaComponent(0.78)
    }

    // 命中的投放区自己也要接受拖拽（窗口级的 contentView 已注册同样的类型）
    override var acceptsFirstResponder: Bool { false }
}

// MARK: - 暂存列表行

final class NotchStagingRow: NSView, NSMenuDelegate, NSDraggingSource {
    var onReveal: ((UUID) -> Void)?
    var onDelete: ((UUID) -> Void)?
    var onMenuVisibility: ((Bool) -> Void)?
    var onDragOut: ((UUID) -> URL?)?

    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let timeLabel = NSTextField(labelWithString: "")
    private(set) var currentID: UUID?
    private static var iconCache: [String: NSImage] = [:]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.05).cgColor

        iconView.imageScaling = .scaleProportionallyUpOrDown

        nameLabel.font = .systemFont(ofSize: 11, weight: .regular)
        nameLabel.textColor = NSColor.white.withAlphaComponent(0.9)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.cell?.truncatesLastVisibleLine = true

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        timeLabel.textColor = NSColor.white.withAlphaComponent(0.5)
        timeLabel.alignment = .right

        addSubview(iconView)
        addSubview(nameLabel)
        addSubview(timeLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        iconView.frame = NSRect(x: 8, y: (bounds.height - 16) / 2, width: 16, height: 16)
        let timeWidth: CGFloat = 46
        nameLabel.frame = NSRect(x: 32, y: (bounds.height - 16) / 2, width: max(20, bounds.width - 32 - timeWidth - 8), height: 16)
        timeLabel.frame = NSRect(x: bounds.width - timeWidth - 8, y: (bounds.height - 16) / 2, width: timeWidth, height: 16)
    }

    func update(with file: StagedFile) {
        if currentID != file.id { currentID = file.id }
        nameLabel.stringValue = file.displayName
        timeLabel.stringValue = NotchStagingRow.format(file.remaining)
        if let cached = NotchStagingRow.iconCache[file.url.path] {
            iconView.image = cached
        } else {
            let icon = NSWorkspace.shared.icon(forFile: file.url.path)
            icon.size = NSSize(width: 16, height: 16)
            NotchStagingRow.iconCache[file.url.path] = icon
            iconView.image = icon
        }
    }

    static func format(_ remaining: TimeInterval) -> String {
        let total = Int(remaining.rounded(.down))
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    // MARK: 菜单

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.delegate = self
        let reveal = NSMenuItem(title: "在 Finder 中显示", action: #selector(revealTapped), keyEquivalent: "")
        reveal.target = self
        let delete = NSMenuItem(title: "删除", action: #selector(deleteTapped), keyEquivalent: "")
        delete.target = self
        menu.addItem(reveal)
        menu.addItem(delete)
        return menu
    }

    func menuWillOpen(_ menu: NSMenu) { onMenuVisibility?(true) }
    func menuDidClose(_ menu: NSMenu) { onMenuVisibility?(false) }

    @objc private func revealTapped() {
        guard let id = currentID else { return }
        onReveal?(id)
    }

    @objc private func deleteTapped() {
        guard let id = currentID else { return }
        onDelete?(id)
    }

    // MARK: 拖出到 Finder

    override func mouseDragged(with event: NSEvent) {
        guard let id = currentID, let url = onDragOut?(id) else { return }
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let image = NSImage(size: NSSize(width: 32, height: 32))
        image.lockFocus()
        if let fileIcon = iconView.image {
            fileIcon.draw(in: NSRect(x: 0, y: 0, width: 32, height: 32))
        }
        image.unlockFocus()
        item.setDraggingFrame(NSRect(x: 0, y: 0, width: 32, height: 32), contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return .copy
    }
}

// MARK: - 底部小按钮（设置 / 退出）

final class NotchFooterButton: NSButton {
    private var hoverTracking: NSTrackingArea?
    private var isHovered = false {
        didSet { updateAppearance() }
    }

    init(symbol: String, label: String) {
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        imagePosition = .imageOnly
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        contentTintColor = NSColor.white.withAlphaComponent(0.6)
        toolTip = label
        setAccessibilityLabel(label)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// nonactivating 面板第一次点击就要命中，但不激活 Perch。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    private func updateAppearance() {
        layer?.backgroundColor = (isHovered ? NSColor.white.withAlphaComponent(0.14) : NSColor.clear).cgColor
        contentTintColor = NSColor.white.withAlphaComponent(isHovered ? 0.95 : 0.6)
    }
}

// MARK: - 面板内容

final class NotchContentView: NSView {
    var onDragEnter: (() -> Void)?
    var onDragExit: (() -> Void)?
    var onDrop: ((NotchZoneKind, [URL]) -> Void)?
    var onListHeightChange: (() -> Void)?
    var onMenuVisibility: ((Bool) -> Void)?
    var onReveal: ((UUID) -> Void)?
    var onDelete: ((UUID) -> Void)?
    var onMouseEnter: (() -> Void)?
    var onSettings: (() -> Void)?
    var onQuit: (() -> Void)?

    private(set) var isExpanded = false
    private var hoverTracking: NSTrackingArea?
    var topInset: CGFloat = 0 {
        didSet { needsLayout = true }
    }
    var showsCollapsedHint = false {
        didSet { hintView.isHidden = !showsCollapsedHint }
    }

    private let revealContainer = NSView()
    private let airZone = NotchDropZoneView(kind: .airDrop)
    private let stagingZone = NotchDropZoneView(kind: .staging)
    static let footerHeight: CGFloat = 26

    private let messageLabel = NSTextField(labelWithString: "")
    private let overflowLabel = NSTextField(labelWithString: "")
    private let hintView = NSImageView()
    private let settingsButton = NotchFooterButton(symbol: "gearshape", label: "设置")
    private let quitButton = NotchFooterButton(symbol: "power", label: "退出")
    private var rows: [NotchStagingRow] = []
    private var messageText: String = ""
    private var files: [StagedFile] = []
    /// 目标布局尺寸：窗口动画期间 bounds 仍在变化，投放区/列表按最终尺寸布局，
    /// 保证拖拽进入瞬间的命中判定稳定。
    private var layoutSize: CGSize?

    private var effectiveSize: CGSize { layoutSize ?? bounds.size }

    func setLayoutSize(_ size: CGSize) {
        layoutSize = size
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    func resetLayoutSize() {
        layoutSize = nil
        needsLayout = true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        layer?.cornerCurve = .continuous
        layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        layer?.cornerRadius = 10

        revealContainer.wantsLayer = true
        revealContainer.layer?.backgroundColor = NSColor.clear.cgColor
        revealContainer.autoresizingMask = [.width, .height]
        revealContainer.alphaValue = 0

        messageLabel.font = .systemFont(ofSize: 10, weight: .regular)
        messageLabel.textColor = NSColor.white.withAlphaComponent(0.65)
        messageLabel.alignment = .center
        messageLabel.lineBreakMode = .byTruncatingTail

        overflowLabel.font = .systemFont(ofSize: 10, weight: .regular)
        overflowLabel.textColor = NSColor.white.withAlphaComponent(0.45)
        overflowLabel.alignment = .center

        hintView.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "展开")
        hintView.contentTintColor = NSColor.white.withAlphaComponent(0.28)
        hintView.imageScaling = .scaleProportionallyUpOrDown
        hintView.isHidden = true

        addSubview(revealContainer)
        revealContainer.addSubview(airZone)
        revealContainer.addSubview(stagingZone)
        revealContainer.addSubview(messageLabel)
        revealContainer.addSubview(overflowLabel)
        settingsButton.target = self
        settingsButton.action = #selector(settingsTapped)
        quitButton.target = self
        quitButton.action = #selector(quitTapped)
        revealContainer.addSubview(settingsButton)
        revealContainer.addSubview(quitButton)

        addSubview(hintView)

        registerForDraggedTypes([.fileURL])
        for _ in 0..<3 { rows.append(makeRow()) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func makeRow() -> NotchStagingRow {
        let row = NotchStagingRow(frame: .zero)
        row.onReveal = { [weak self] id in self?.onReveal?(id) }
        row.onDelete = { [weak self] id in self?.onDelete?(id) }
        row.onMenuVisibility = { [weak self] visible in self?.onMenuVisibility?(visible) }
        row.onDragOut = { [weak self] id in self?.files.first(where: { $0.id == id })?.url }
        row.isHidden = true
        revealContainer.addSubview(row)
        return row
    }

    @objc private func settingsTapped() { onSettings?() }
    @objc private func quitTapped() { onQuit?() }

    // MARK: 状态

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        onMouseEnter?()
    }

    func setExpanded(_ expanded: Bool) {
        isExpanded = expanded
        revealContainer.alphaValue = expanded ? 1 : 0
        hintView.isHidden = expanded || !showsCollapsedHint
        layer?.cornerRadius = expanded ? 20 : cornerRadiusCollapsed
        needsLayout = true
    }

    private var cornerRadiusCollapsed: CGFloat = 10

    func setCollapsedCornerRadius(_ radius: CGFloat) {
        cornerRadiusCollapsed = radius
        if !isExpanded { layer?.cornerRadius = radius }
    }

    func update(files newFiles: [StagedFile]) {
        files = newFiles
        for (index, row) in rows.enumerated() {
            if index < min(files.count, rows.count) {
                row.update(with: files[index])
                row.isHidden = false
            } else {
                row.isHidden = true
            }
        }
        if files.count > rows.count {
            overflowLabel.stringValue = "还有 \(files.count - rows.count) 项"
            overflowLabel.isHidden = false
        } else {
            overflowLabel.isHidden = true
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
        onListHeightChange?()
    }

    func showMessage(_ text: String) {
        messageText = text
        messageLabel.stringValue = text
        messageLabel.isHidden = text.isEmpty
        needsLayout = true
        layoutSubtreeIfNeeded()
        onListHeightChange?()
    }

    /// 展开态在 96pt 之外的附加高度（footer + 提示行 + 列表）。
    var listHeight: CGFloat {
        var height: CGFloat = NotchContentView.footerHeight
        if !messageText.isEmpty { height += 26 }
        let visibleRows = min(files.count, rows.count)
        if visibleRows > 0 { height += CGFloat(visibleRows) * 30 + 4 }
        if files.count > rows.count { height += 18 }
        return height
    }

    func setHighlight(_ kind: NotchZoneKind?) {
        airZone.setHighlighted(kind == .airDrop)
        stagingZone.setHighlighted(kind == .staging)
    }

    func zone(atWindowPoint point: NSPoint) -> NotchZoneKind? {
        for zone in [airZone, stagingZone] {
            let rect = zone.convert(zone.bounds, to: nil).insetBy(dx: -10, dy: -10)
            if rect.contains(point) { return zone.kind }
        }
        return nil
    }

    // MARK: 布局

    override func layout() {
        super.layout()
        revealContainer.frame = bounds

        let size = effectiveSize
        let width = size.width
        let contentTop = size.height - topInset
        let zoneAreaBottom = contentTop - NotchGeometry.revealHeight

        let airSize = NSSize(width: 64, height: 64)
        let stagingSize = NSSize(width: 132, height: 64)
        let gap: CGFloat = 16
        let totalWidth = airSize.width + gap + stagingSize.width
        let startX = max(8, (width - totalWidth) / 2)
        let zoneY = zoneAreaBottom + (NotchGeometry.revealHeight - airSize.height) / 2

        airZone.frame = NSRect(x: startX, y: zoneY, width: airSize.width, height: airSize.height)
        stagingZone.frame = NSRect(x: startX + airSize.width + gap, y: zoneY, width: stagingSize.width, height: stagingSize.height)

        var cursor = zoneAreaBottom
        messageLabel.isHidden = messageText.isEmpty
        if !messageText.isEmpty {
            messageLabel.frame = NSRect(x: 14, y: cursor - 22, width: max(20, width - 28), height: 16)
            cursor -= 26
        }

        let rowWidth = max(80, width - 24)
        for (index, row) in rows.enumerated() {
            guard index < min(files.count, rows.count) else {
                row.isHidden = true
                continue
            }
            row.isHidden = false
            row.frame = NSRect(x: 12, y: cursor - 30, width: rowWidth, height: 26)
            cursor -= 30
        }

        overflowLabel.isHidden = files.count <= rows.count
        if !overflowLabel.isHidden {
            overflowLabel.frame = NSRect(x: 12, y: cursor - 18, width: rowWidth, height: 14)
        }

        let buttonSize: CGFloat = 20
        let buttonGap: CGFloat = 6
        let footerY: CGFloat = 3
        quitButton.frame = NSRect(x: width - 10 - buttonSize, y: footerY, width: buttonSize, height: buttonSize)
        settingsButton.frame = NSRect(x: width - 10 - buttonSize * 2 - buttonGap, y: footerY, width: buttonSize, height: buttonSize)

        hintView.frame = NSRect(x: (bounds.width - 14) / 2, y: (bounds.height - 14) / 2, width: 14, height: 14)
    }

    // MARK: 拖拽

    private func fileURLs(from info: NSDraggingInfo) -> [URL] {
        let pasteboard = info.draggingPasteboard
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]
        return (objects ?? []).filter { $0.isFileURL }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !fileURLs(from: sender).isEmpty else { return [] }
        onDragEnter?()
        layoutSubtreeIfNeeded()
        let kind = zone(atWindowPoint: sender.draggingLocation)
        setHighlight(kind)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !fileURLs(from: sender).isEmpty else { return [] }
        let kind = zone(atWindowPoint: sender.draggingLocation)
        setHighlight(kind)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        setHighlight(nil)
        onDragExit?()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        return !fileURLs(from: sender).isEmpty
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(from: sender)
        guard !urls.isEmpty else { return false }
        let kind = zone(atWindowPoint: sender.draggingLocation)
        setHighlight(nil)
        guard let kind else { return false }
        onDrop?(kind, urls)
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        setHighlight(nil)
    }

    override func wantsPeriodicDraggingUpdates() -> Bool { false }

    // 空白区域点击不激活
    override var acceptsFirstResponder: Bool { false }
}
