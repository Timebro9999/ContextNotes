import AppKit

// MARK: - 便签卡片

/// 一张便签。默认折叠显示两行，点一下展开全文。
final class NoteCardView: NSView {

    private let bodyLabel = NSTextField(wrappingLabelWithString: "")
    private var expanded = false
    private var tracking: NSTrackingArea?

    private static var idleFill: NSColor { Palette.cardFill }
    private static var hoverFill: NSColor { Palette.cardHover }

    init(note: Note, subtitle: String?) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = Self.idleFill.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = Palette.cardBorder.cgColor

        var rows: [NSView] = []

        // 窗口标题如果和分区名一样，就不重复显示了
        if let titleText = Self.titleText(for: note) {
            let title = NSTextField(labelWithString: titleText)
            title.font = .systemFont(ofSize: 12.5, weight: .semibold)
            title.textColor = .labelColor
            title.lineBreakMode = .byTruncatingTail
            title.maximumNumberOfLines = 1
            rows.append(title)
        }

        bodyLabel.stringValue = note.body
        bodyLabel.font = .systemFont(ofSize: 11.5)
        bodyLabel.textColor = .secondaryLabelColor
        bodyLabel.maximumNumberOfLines = 2
        bodyLabel.lineBreakMode = .byTruncatingTail

        let meta = NSTextField(labelWithString: Fmt.label(for: note.updatedAt))
        meta.font = .systemFont(ofSize: 10)
        meta.textColor = .tertiaryLabelColor

        rows.append(bodyLabel)
        rows.append(meta)

        // 来源路径放进卡片里，不再飘在卡片外面
        if let subtitle, !subtitle.isEmpty {
            let path = NSTextField(labelWithString: subtitle)
            path.font = .systemFont(ofSize: 10)
            path.textColor = .tertiaryLabelColor
            path.lineBreakMode = .byTruncatingMiddle
            path.maximumNumberOfLines = 1
            rows.append(path)
        }

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 11),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 13),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -13),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -11),
            bodyLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        for view in rows {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 标题优先用窗口标题；Word 这类给的是文件名，直接可用
    private static func titleText(for note: Note) -> String? {
        let ctx = note.context
        if let title = ctx.windowTitle, !title.isEmpty, title != ctx.appName {
            return title
        }
        // 和分区名重复时省略，避免"微信 / 微信"
        return nil
    }

    // MARK: 交互

    override func mouseDown(with event: NSEvent) {
        expanded.toggle()
        bodyLabel.maximumNumberOfLines = expanded ? 0 : 2
        bodyLabel.invalidateIntrinsicContentSize()
        needsLayout = true
        superview?.needsLayout = true
        superview?.superview?.needsLayout = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = Self.hoverFill.cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = Self.idleFill.cgColor
    }
}

/// NSScrollView 的文档视图必须是 flipped，否则内容会被按底对齐、顶上留白
final class FlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
}

// MARK: - 路径美化

enum Pretty {
    /// file:///Users/x/Desktop/%E5%A4%A7... → ~/Desktop/大论文/大论文草稿.docx
    static func location(_ ctx: NoteContext) -> String? {
        if let raw = ctx.documentPath, !raw.isEmpty {
            if let url = URL(string: raw), url.isFileURL {
                return shorten(url.path)
            }
            return shorten(raw)
        }
        if let url = ctx.url, !url.isEmpty { return url }
        return nil
    }

    static func shorten(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

// MARK: - 主窗口

/// 所有便签，按 App 分区。
final class MainWindowController: NSObject, NSWindowDelegate, NSTextFieldDelegate {

    private let window: NSWindow
    private let searchField = NSTextField()
    private let scrollView = NSScrollView()
    private let board = FlippedStackView()
    private let footerLabel = NSTextField(labelWithString: "")
    private var glassView: NSView?

    private var allNotes: [Note] = []
    private var query = ""

    override init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 580),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()
        build()
    }

    // MARK: 构建

    private func build() {
        window.title = "所有便签"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 520, height: 380)
        window.setFrameAutosaveName("ContextNotesMainWindow")
        window.delegate = self

        let made = Glass.makeBackground()
        glassView = made.background
        window.contentView = made.background
        Glass.apply(AppearanceStore.shared.value, to: made.background)
        let container = made.container

        // 标题
        let titleLabel = NSTextField(labelWithString: "所有便签")
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        container.addSubview(titleLabel)

        // 搜索框：放在胶囊底上
        let searchPill = Glass.roundedFill(
            Palette.pillFill,
            radius: 13,
            border: Palette.pillBorder
        )
        searchPill.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(searchPill)

        // 不用 NSSearchField：它自带的 cell 在自绘胶囊里会错位叠字
        let searchIcon = NSImageView()
        searchIcon.translatesAutoresizingMaskIntoConstraints = false
        searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        searchIcon.contentTintColor = .tertiaryLabelColor
        searchIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        searchPill.addSubview(searchIcon)

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "搜索应用、窗口、路径或内容"
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.font = .systemFont(ofSize: 12.5)
        searchField.delegate = self
        searchPill.addSubview(searchField)

        NSLayoutConstraint.activate([
            searchIcon.leadingAnchor.constraint(equalTo: searchPill.leadingAnchor, constant: 10),
            searchIcon.centerYAnchor.constraint(equalTo: searchPill.centerYAnchor),
            searchIcon.widthAnchor.constraint(equalToConstant: 13),
            searchIcon.heightAnchor.constraint(equalToConstant: 13),
            searchField.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: 6),
        ])

        // 列表
        board.translatesAutoresizingMaskIntoConstraints = false
        board.orientation = .vertical
        board.alignment = .leading
        board.spacing = 18

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = board
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.scrollerStyle = .overlay
        // fullSizeContentView 下系统会自动加安全区内边距，导致顶部空一大块
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsetsZero
        container.addSubview(scrollView)

        footerLabel.translatesAutoresizingMaskIntoConstraints = false
        footerLabel.font = .systemFont(ofSize: 10.5)
        footerLabel.textColor = .tertiaryLabelColor
        container.addSubview(footerLabel)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 9),
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 78),

            searchPill.topAnchor.constraint(equalTo: container.topAnchor, constant: 36),
            searchPill.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            searchPill.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            searchPill.heightAnchor.constraint(equalToConstant: 28),

            searchField.trailingAnchor.constraint(equalTo: searchPill.trailingAnchor, constant: -10),
            searchField.centerYAnchor.constraint(equalTo: searchPill.centerYAnchor),

            scrollView.topAnchor.constraint(equalTo: searchPill.bottomAnchor, constant: 14),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            scrollView.bottomAnchor.constraint(equalTo: footerLabel.topAnchor, constant: -10),

            board.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            board.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            board.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),

            footerLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            footerLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),
        ])

        reload()
    }

    // MARK: 展示

    func show() {
        reload()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func controlTextDidChange(_ notification: Notification) {
        query = searchField.stringValue
        rebuildBoard()
    }

    func reload() {
        allNotes = Store.shared.all()
        rebuildBoard()
    }

    // MARK: 分区渲染

    private func rebuildBoard() {
        board.arrangedSubviews.forEach {
            board.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = needle.isEmpty ? allNotes : allNotes.filter {
            $0.context.matches(needle) || $0.body.lowercased().contains(needle)
        }

        // 按 App 分组，组内按更新时间倒序
        var order: [String] = []
        var groups: [String: [Note]] = [:]
        for note in filtered {
            let key = note.context.appKey
            if groups[key] == nil {
                groups[key] = []
                order.append(key)
            }
            groups[key]?.append(note)
        }

        if filtered.isEmpty {
            let empty = NSTextField(wrappingLabelWithString: needle.isEmpty
                ? "还没有任何便签。\n在任何程序里按 ⌥⌘N 就能记一条。"
                : "没有匹配的记录。")
            empty.font = .systemFont(ofSize: 12)
            empty.textColor = .tertiaryLabelColor
            empty.alignment = .center
            empty.translatesAutoresizingMaskIntoConstraints = false
            board.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: board.widthAnchor).isActive = true
            empty.heightAnchor.constraint(equalToConstant: 90).isActive = true
        }

        for key in order {
            guard let notes = groups[key], let first = notes.first else { continue }
            let section = makeSection(context: first.context, notes: notes)
            board.addArrangedSubview(section)
            section.widthAnchor.constraint(equalTo: board.widthAnchor).isActive = true
        }

        let appCount = groups.count
        footerLabel.stringValue = needle.isEmpty
            ? "共 \(filtered.count) 条  ·  \(appCount) 个应用  ·  点击便签展开全文"
            : "匹配 \(filtered.count) 条  ·  \(appCount) 个应用"
    }

    private func makeSection(context: NoteContext, notes: [Note]) -> NSView {
        let section = NSStackView()
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 8
        section.translatesAutoresizingMaskIntoConstraints = false

        // 分区头：应用图标 + 名称 + 条数
        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = Self.appIcon(for: context.bundleID)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 18).isActive = true

        let name = NSTextField(labelWithString: context.appName)
        name.font = .systemFont(ofSize: 12, weight: .semibold)
        name.textColor = .labelColor

        let count = NSTextField(labelWithString: "\(notes.count) 条")
        count.font = .systemFont(ofSize: 10.5)
        count.textColor = .tertiaryLabelColor

        let header = NSStackView(views: [icon, name, count])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 7
        section.addArrangedSubview(header)

        for note in notes {
            let card = NoteCardView(note: note, subtitle: Pretty.location(note.context))
            section.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        }

        return section
    }

    private static func appIcon(for bundleID: String?) -> NSImage? {
        if let bundleID,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)
    }

    // MARK: 外观

    /// 主题变更后调用：重刷玻璃与卡片配色
    func applyAppearance() {
        guard let glassView else { return }
        Glass.apply(AppearanceStore.shared.value, to: glassView)
        rebuildBoard()
    }

    func windowDidResize(_ notification: Notification) {
        if let glassView {
            Glass.apply(AppearanceStore.shared.value, to: glassView)
        }
    }
}
