import AppKit

// MARK: - 输入框

/// 接管 Esc 与 ⌘↩
final class InputTextView: NSTextView {
    var onCommit: (() -> Void)?
    var onAdjustGlass: ((Int) -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // esc
            onCommit?()
            return
        case 33, 30: // [ / ]
            if event.modifierFlags.contains(.command) {
                onAdjustGlass?(event.keyCode == 30 ? 1 : -1)
                return
            }
        case 36, 76: // return / enter
            if event.modifierFlags.contains(.command) {
                onCommit?()
                return
            }
        default:
            break
        }
        super.keyDown(with: event)
    }
}

// MARK: - 面板

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    var onEscape: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onEscape?()
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}

/// 一张便签。呼出即写，写的是"这个位置"的那张。
/// 视觉上是一块 Liquid Glass（macOS 26+ 用 NSGlassEffectView，低版本退回 NSVisualEffectView）。
final class NotePanelController: NSObject, NSTextViewDelegate, NSWindowDelegate {

    private let panel: FloatingPanel
    private let textView = InputTextView()
    private let scrollView = NSScrollView()
    private let placeholder = NSTextField(labelWithString: "记点什么…")
    private let statusLabel = NSTextField(labelWithString: "")

    private var context: NoteContext?
    private var openedBody: String = ""
    private var isVisible = false
    private var glassView: NSView?
    private let appearancePopover = NSPopover()

    private static let size = NSSize(width: 440, height: 340)

    override init() {
        panel = FloatingPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable,
                        .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()
        build()
    }

    // MARK: - 构建

    private func build() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.minSize = NSSize(width: 320, height: 240)
        panel.delegate = self
        panel.onEscape = { [weak self] in self?.commit() }

        // 玻璃背景 + 内容层
        let made = Glass.makeBackground()
        glassView = made.background
        panel.contentView = made.background
        applyAppearance()
        let container = made.container

        buildContent(in: container)
        buildAppearancePopover()
    }

    /// 把外观设置应用到玻璃上；任何时候改都能即时生效
    func applyAppearance() {
        let look = AppearanceStore.shared.value
        panel.animator().alphaValue = 1

        if #available(macOS 26.0, *), let glass = glassView as? NSGlassEffectView {
            glass.style = (look.style == "clear") ? .clear : .regular
            glass.cornerRadius = CGFloat(look.cornerRadius)
            glass.tintColor = NSColor.white.withAlphaComponent(CGFloat(look.tint))
        } else if let fx = glassView as? NSVisualEffectView {
            // 低版本没有浓度 API，用叠一层半透明白来近似
            fx.material = (look.style == "clear") ? .underWindowBackground : .hudWindow
        }
    }

    private func buildContent(in container: NSView) {
        // 标题：避开红绿灯
        let titleLabel = NSTextField(labelWithString: "便签")
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        container.addSubview(titleLabel)

        // 正文
        textView.isEditable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.insertionPointColor = .labelColor
        textView.textContainerInset = .zero
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.font = Self.noteFont
        textView.textColor = .labelColor
        textView.delegate = self
        textView.onCommit = { [weak self] in self?.commit() }
        textView.onAdjustGlass = { [weak self] direction in self?.adjustTint(direction) }

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.scrollerStyle = .overlay
        container.addSubview(scrollView)

        placeholder.translatesAutoresizingMaskIntoConstraints = false
        placeholder.font = Self.noteFont
        placeholder.textColor = .labelColor.withAlphaComponent(0.32)
        container.addSubview(placeholder)

        // 底部状态
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: 10.5)
        statusLabel.textColor = .tertiaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        container.addSubview(statusLabel)

        // 操作按钮
        let lookButton = makeButton("circle.lefthalf.filled", tooltip: "外观", action: #selector(showAppearance))
        self.lookButton = lookButton
        let copyButton = makeButton("doc.on.doc", tooltip: "复制全文", action: #selector(copyContent))
        let listButton = makeButton("list.bullet.rectangle", tooltip: "所有便签", action: #selector(showAll))
        let deleteButton = makeButton("trash", tooltip: "删除这张便签", action: #selector(deleteNote))

        let actions = NSStackView(views: [lookButton, copyButton, listButton, deleteButton])
        actions.translatesAutoresizingMaskIntoConstraints = false
        actions.orientation = .horizontal
        actions.spacing = 6
        container.addSubview(actions)

        // 工具栏分隔线
        let divider = NSBox()
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.boxType = .separator
        container.addSubview(divider)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 9),
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 78),

            scrollView.topAnchor.constraint(equalTo: container.topAnchor, constant: 40),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            scrollView.bottomAnchor.constraint(equalTo: divider.topAnchor, constant: -8),

            placeholder.topAnchor.constraint(equalTo: scrollView.topAnchor),
            placeholder.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 2),

            divider.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            divider.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            divider.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -10),

            actions.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            actions.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),
            actions.heightAnchor.constraint(equalToConstant: 26),

            statusLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            statusLabel.centerYAnchor.constraint(equalTo: actions.centerYAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: actions.leadingAnchor, constant: -10),
        ])
    }

    private func makeButton(_ symbol: String, tooltip: String, action: Selector) -> NSButton {
        let button = NSButton()
        button.translatesAutoresizingMaskIntoConstraints = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        button.imagePosition = .imageOnly
        button.isBordered = true
        if #available(macOS 26.0, *) {
            button.bezelStyle = .glass
        } else {
            button.bezelStyle = .texturedRounded
        }
        button.target = self
        button.action = action
        button.toolTip = tooltip
        button.setAccessibilityLabel(tooltip)
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        button.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return button
    }

    // MARK: - 外观调节

    private weak var lookButton: NSButton?
    private let tintSlider = NSSlider()
    private let radiusSlider = NSSlider()
    private let tintValue = NSTextField(labelWithString: "")
    private let radiusValue = NSTextField(labelWithString: "")
    private let styleControl = NSSegmentedControl(
        labels: ["常规", "通透"], trackingMode: .selectOne, target: nil, action: nil
    )
    private let themeControl = NSSegmentedControl(
        labels: ["随系统", "浅色", "深色"], trackingMode: .selectOne, target: nil, action: nil
    )

    private func buildAppearancePopover() {
        let look = AppearanceStore.shared.value

        for slider in [tintSlider, radiusSlider] {
            slider.isContinuous = true
            slider.controlSize = .small
            slider.translatesAutoresizingMaskIntoConstraints = false
            slider.widthAnchor.constraint(equalToConstant: 132).isActive = true
        }

        tintSlider.minValue = Appearance.minTint
        tintSlider.maxValue = Appearance.maxTint
        tintSlider.doubleValue = look.tint
        tintSlider.target = self
        tintSlider.action = #selector(tintChanged)

        radiusSlider.minValue = 0
        radiusSlider.maxValue = 28
        radiusSlider.doubleValue = look.cornerRadius
        radiusSlider.target = self
        radiusSlider.action = #selector(radiusChanged)

        styleControl.selectedSegment = (look.style == "clear") ? 1 : 0
        styleControl.controlSize = .small
        styleControl.target = self
        styleControl.action = #selector(styleChanged)

        switch look.theme {
        case "light": themeControl.selectedSegment = 1
        case "dark":  themeControl.selectedSegment = 2
        default:      themeControl.selectedSegment = 0
        }
        themeControl.controlSize = .small
        themeControl.target = self
        themeControl.action = #selector(themeChanged)

        for label in [tintValue, radiusValue] {
            label.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
            label.textColor = .secondaryLabelColor
        }
        refreshAppearanceLabels()

        func caption(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            return label
        }

        let grid = NSGridView(views: [
            [caption("主题"), themeControl, NSGridCell.emptyContentView],
            [caption("玻璃浓度"), tintSlider, tintValue],
            [caption("风格"), styleControl, NSGridCell.emptyContentView],
            [caption("圆角"), radiusSlider, radiusValue],
        ])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 12
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 288, height: 174))
        container.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -16),
            grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            grid.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -16),
        ])

        let vc = NSViewController()
        vc.view = container
        appearancePopover.contentViewController = vc
        appearancePopover.behavior = .transient
    }

    private func refreshAppearanceLabels() {
        tintValue.stringValue = String(format: "%.0f%%", AppearanceStore.shared.value.tint * 100)
        radiusValue.stringValue = String(format: "%.0f", AppearanceStore.shared.value.cornerRadius)
    }

    @objc private func showAppearance() {
        guard !appearancePopover.isShown, let button = lookButton else { return }
        appearancePopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    @objc private func tintChanged() {
        AppearanceStore.shared.update { $0.tint = tintSlider.doubleValue }
        refreshAppearanceLabels()
        applyAppearance()
    }

    @objc private func radiusChanged() {
        AppearanceStore.shared.update { $0.cornerRadius = radiusSlider.doubleValue }
        refreshAppearanceLabels()
        applyAppearance()
    }

    @objc private func themeChanged() {
        let value: String
        switch themeControl.selectedSegment {
        case 1: value = "light"
        case 2: value = "dark"
        default: value = "system"
        }
        AppearanceStore.shared.update { $0.theme = value }
        NotificationCenter.default.post(name: .contextNotesThemeChanged, object: nil)
    }

    @objc private func styleChanged() {
        AppearanceStore.shared.update {
            $0.style = (styleControl.selectedSegment == 1) ? "clear" : "regular"
        }
        applyAppearance()
    }

    /// ⌘[ / ⌘] 快速调浓度
    private func adjustTint(_ direction: Int) {
        let step = 0.06 * Double(direction)
        AppearanceStore.shared.update {
            $0.tint = min(max($0.tint + step, Appearance.minTint), Appearance.maxTint)
        }
        tintSlider.doubleValue = AppearanceStore.shared.value.tint
        refreshAppearanceLabels()
        applyAppearance()
    }

    private static var noteFont: NSFont {
        let base = NSFont.systemFont(ofSize: 14.5, weight: .regular)
        if let rounded = base.fontDescriptor.withDesign(.rounded) {
            return NSFont(descriptor: rounded, size: 14.5) ?? base
        }
        return base
    }

    // MARK: - 显示

    func toggle() {
        if isVisible { commit() } else { show() }
    }

    func show() {
        let ctx = ContextCapture.capture()
        context = ctx

        let existing = Store.shared.note(for: ctx)
        let body = existing?.body ?? ""
        openedBody = body
        textView.string = body

        if let existing {
            statusLabel.stringValue = "上次编辑 " + Fmt.label(for: existing.updatedAt)
        } else {
            statusLabel.stringValue = "新便签"
        }

        Debug.log("show: ax=\(ContextCapture.hasAccessibility) anchor=\(ctx.key)")
        refreshPlaceholder()
        applyTextStyle()
        restoreFrame()

        isVisible = true
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: (body as NSString).length, length: 0))
        textView.scrollToEndOfDocument(nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self,
                  ProcessInfo.processInfo.environment["CTXNOTE_DEBUG"] != nil else { return }
            let line = "active=\(NSApp.isActive) key=\(self.panel.isKeyWindow) "
                + "fr=\(String(describing: self.panel.firstResponder.map { type(of: $0) }))\n"
            let url = URL(fileURLWithPath: "/tmp/contextnotes-diag.log")
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(line.data(using: .utf8) ?? Data())
                handle.closeFile()
            } else {
                try? line.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    private func applyTextStyle() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3.5
        guard let storage = textView.textStorage else { return }
        storage.addAttributes([
            .font: Self.noteFont,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ], range: NSRange(location: 0, length: storage.length))
    }

    private func positionPanel() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size
        let x = visible.midX - size.width / 2
        let y = visible.midY - size.height / 2 + visible.height * 0.10
        panel.setFrameOrigin(NSPoint(x: x, y: max(y, visible.minY + 40)))
    }

    // MARK: - 窗口位置记忆

    /// 恢复上次关闭时的位置与大小；不可用时退回居中
    private func restoreFrame() {
        guard let saved = AppearanceStore.shared.value.frame else {
            positionPanel()
            return
        }
        var rect = NSRect(x: saved.x, y: saved.y, width: saved.w, height: saved.h)
        rect.size.width = max(Appearance.minWidth, rect.width)
        rect.size.height = max(Appearance.minHeight, rect.height)

        // 屏幕换了 / 拔了外接屏，旧坐标可能落在屏幕外
        let onSomeScreen = NSScreen.screens.contains { $0.visibleFrame.intersects(rect) }
        guard onSomeScreen else {
            positionPanel()
            return
        }
        panel.setFrame(rect, display: false)
    }

    private func saveFrame() {
        let f = panel.frame
        AppearanceStore.shared.update {
            $0.frame = Appearance.Frame(
                x: Double(f.origin.x), y: Double(f.origin.y),
                w: Double(f.width), h: Double(f.height)
            )
        }
    }

    private var frameSaveWork: DispatchWorkItem?

    /// 拖动/缩放时防抖保存，避免每帧写盘
    private func scheduleFrameSave() {
        frameSaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveFrame() }
        frameSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    func windowDidMove(_ notification: Notification) { scheduleFrameSave() }
    func windowDidResize(_ notification: Notification) { scheduleFrameSave() }
    func windowDidEndLiveResize(_ notification: Notification) { scheduleFrameSave() }

    // MARK: - 文本

    func textDidChange(_ notification: Notification) {
        refreshPlaceholder()
    }

    private func refreshPlaceholder() {
        placeholder.isHidden = !textView.string.isEmpty
    }

    // MARK: - 动作

    /// 供菜单 ⇧⌘C 调用
    func copyBodyToPasteboard() {
        copyContent()
    }

    @objc private func copyContent() {
        let body = textView.string
        guard !body.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(body, forType: .string)
        flashStatus("已复制")
    }

    @objc private func showAll() {
        persist()
        NotificationCenter.default.post(name: .contextNotesShowAll, object: nil)
    }

    @objc private func deleteNote() {
        guard let ctx = context, let note = Store.shared.note(for: ctx) else { return }
        Store.shared.delete(id: note.id)
        textView.string = ""
        openedBody = ""
        refreshPlaceholder()
        statusLabel.stringValue = "已删除"
    }

    private func flashStatus(_ text: String) {
        statusLabel.stringValue = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let self, let ctx = self.context else { return }
            if let note = Store.shared.note(for: ctx) {
                self.statusLabel.stringValue = "上次编辑 " + Fmt.label(for: note.updatedAt)
            } else {
                self.statusLabel.stringValue = "新便签"
            }
        }
    }

    // MARK: - 保存

    private func persist() {
        guard let ctx = context else { return }
        let body = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        if body == openedBody, Store.shared.note(for: ctx) != nil { return }
        Store.shared.save(body: body, color: NoteColor.yellow.rawValue, context: ctx)
        openedBody = body
    }

    func commit() {
        persist()
        saveFrame()
        close()
    }

    func close() {
        isVisible = false
        panel.orderOut(nil)
        if let previous = ContextCapture.lastExternalApp,
           previous.bundleIdentifier != Bundle.main.bundleIdentifier {
            previous.activate()
        } else {
            NSApp.hide(nil)
        }
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        persist()
        saveFrame()
        isVisible = false
        return true
    }
}

extension Notification.Name {
    static let contextNotesShowAll = Notification.Name("com.aabananaaa.contextnotes.showAllRequested")
    static let contextNotesThemeChanged = Notification.Name("com.aabananaaa.contextnotes.themeChanged")
}
