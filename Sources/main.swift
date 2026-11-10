import AppKit
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate {

    static private(set) var shared: AppDelegate!

    /// NSApplication.delegate 是 weak，必须在这里强持有，
    /// 否则 delegate 会在 app.run() 之前被释放，applicationDidFinishLaunching 永不触发。
    static var retained: AppDelegate?

    private var statusItem: NSStatusItem!
    private var panelController: NotePanelController!
    private var mainWindowController: MainWindowController!
    private var hotKeyRef: EventHotKeyRef?
    private var appearanceObservation: NSKeyValueObservation?
    private var axReminderShown = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("[ContextNotes] 启动完成")
        AppDelegate.shared = self

        // 单实例：安装脚本 + 登录自启可能各拉起一个，只保留最早的那个
        let running = NSRunningApplication.runningApplications(
            withBundleIdentifier: Bundle.main.bundleIdentifier ?? ""
        )
        if running.count > 1,
           let oldest = running.min(by: { $0.processIdentifier < $1.processIdentifier }),
           oldest.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            NSApp.terminate(nil)
            return
        }

        applyTheme(AppearanceStore.shared.value.theme)

        // 图标跟随明暗（icns 不支持外观变体，只能在运行时替换 Dock 图标）
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.updateAppIcon() }
        }

        panelController = NotePanelController()
        mainWindowController = MainWindowController()

        setupStatusItem()
        trackFrontmostApps()
        installHotKey()
        setupExternalTriggers()
        updateAppIcon()

        if !ContextCapture.hasAccessibility {
            // 只触发系统自带的授权引导（非阻塞）；不要在这里弹自定义模态框，
            // 否则 runModal 会卡住主线程，把便签面板挡在后面。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                ContextCapture.requestAccessibility()
            }
        }
    }

    /// 点击 Dock 图标时把总面板调出来
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Debug.log("reopen: hasVisibleWindows=\(flag)")
        if !flag { showAllNotes() }
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        updateAppIcon()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref) }
    }

    // MARK: - 状态栏

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // 让系统记住它在菜单栏里的位置（装了新菜单栏工具后不容易被挤掉）
        statusItem.autosaveName = "ContextNotesStatusItem"

        if let button = statusItem.button {
            button.image = AppDelegate.statusBarGlyph()
            button.image?.isTemplate = true
            button.imagePosition = .imageOnly
            button.toolTip = "语境便签"
        }

        let menu = NSMenu()
        menu.addItem(item("呼出便签  ⌥⌘N", #selector(showPanel)))
        menu.addItem(item("所有便签  ⇧⌥⌘N", #selector(showAllNotes)))
        menu.addItem(.separator())
        menu.addItem(item("外观…", #selector(showPanel)))
        menu.addItem(item("授予辅助功能权限…", #selector(grantAccessibility)))
        menu.addItem(item("打开数据文件夹", #selector(openDataFolder)))
        menu.addItem(.separator())
        menu.addItem(item("退出", #selector(quit)))
        statusItem.menu = menu

        // 诊断：确认状态栏项真的建出来了
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, let button = self.statusItem?.button else {
                Debug.log("statusItem=nil")
                return
            }
            Debug.log("status item: image=\(String(describing: button.image?.size)) "
                      + "frame=\(button.frame) visible=\(self.statusItem.isVisible) "
                      + "window=\(String(describing: button.window?.frame))")
        }
    }

    /// 菜单栏图标：一张小纸 + 两行字，用模板模式，系统自动适配深/浅色
    static func statusBarGlyph() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 17), flipped: false) { _ in
            let page = NSRect(x: 4, y: 1.5, width: 10.5, height: 14)
            let outline = NSBezierPath(roundedRect: page, xRadius: 2.4, yRadius: 2.4)
            outline.lineWidth = 1.4
            NSColor.black.setStroke()
            outline.stroke()

            NSColor.black.setFill()
            for (index, width) in [CGFloat(6.0), 4.0].enumerated() {
                let y = page.maxY - 4.4 - CGFloat(index) * 3.6
                let bar = NSRect(x: page.minX + 2.6, y: y, width: width, height: 1.35)
                NSBezierPath(roundedRect: bar, xRadius: 0.7, yRadius: 0.7).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        return i
    }

    // MARK: - 快捷键

    private func installHotKey() {
        registerHotKey(id: 1, keyCode: UInt32(kVK_ANSI_N), modifiers: UInt32(optionKey | cmdKey))
        registerHotKey(id: 2, keyCode: UInt32(kVK_ANSI_N), modifiers: UInt32(optionKey | cmdKey | shiftKey))

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                var hkID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hkID
                )
                let which = hkID.id
                DispatchQueue.main.async {
                    if which == 1 {
                        AppDelegate.shared?.showPanel()
                    } else {
                        AppDelegate.shared?.showAllNotes()
                    }
                }
                return noErr
            },
            1,
            &eventType,
            nil,
            nil
        )
    }

    private var hotKeys: [EventHotKeyRef] = []

    private func registerHotKey(id: UInt32, keyCode: UInt32, modifiers: UInt32) {
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x434E_4F54), id: id) // 'CNOT'
        let status = RegisterEventHotKey(
            keyCode, modifiers, hotKeyID,
            GetApplicationEventTarget(), 0, &ref
        )
        if status == noErr, let ref { hotKeys.append(ref) }
    }

    // MARK: - 外部触发

    /// 允许从命令行 / 脚本唤起面板，便于自动化与调试：
    ///   notifyutil -p com.aabananaaa.contextnotes.show    → 便签面板
    ///   notifyutil -p com.aabananaaa.contextnotes.all     → 总面板
    ///
    /// 注意：notifyutil 发的是 Darwin 通知（notifyd），必须用 Darwin 通知中心监听；
    /// NSDistributedNotificationCenter 走的是 distnoted，收不到 notifyutil 的消息。
    private func setupExternalTriggers() {
        let callback: CFNotificationCallback = { _, _, name, _, _ in
            guard let raw = name?.rawValue as String? else { return }
            DispatchQueue.main.async {
                if raw.hasSuffix(".show") {
                    AppDelegate.shared?.showPanel()
                } else if raw.hasSuffix(".all") {
                    AppDelegate.shared?.showAllNotes()
                }
            }
        }
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        for name in ["com.aabananaaa.contextnotes.show", "com.aabananaaa.contextnotes.all"] {
            CFNotificationCenterAddObserver(
                center, nil, callback, name as CFString, nil, .deliverImmediately
            )
        }

        // 面板里的「所有便签」按钮
        NotificationCenter.default.addObserver(
            forName: .contextNotesShowAll, object: nil, queue: .main
        ) { [weak self] _ in
            self?.showAllNotes()
        }

        // 外观里的主题切换
        NotificationCenter.default.addObserver(
            forName: .contextNotesThemeChanged, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.applyTheme(AppearanceStore.shared.value.theme)
            self.updateAppIcon()
            self.panelController?.applyAppearance()
            self.mainWindowController?.applyAppearance()
        }
    }

    // MARK: - 前台应用跟踪

    private func trackFrontmostApps() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            if app.bundleIdentifier != Bundle.main.bundleIdentifier {
                ContextCapture.lastExternalApp = app
            }
        }
    }

    // MARK: - 动作

    /// 系统图标样式：Default / Dark / Clear / Tinted（可与 Dark 组合）
    private func systemIconTheme() -> String {
        (CFPreferencesCopyAppValue(
            "AppleIconAppearanceTheme" as CFString,
            kCFPreferencesAnyApplication
        ) as? String ?? "").lowercased()
    }

    /// Dock 图标换成当前系统图标样式对应的那一张。
    /// 系统把「图标样式」和「外观浅/深」编在同一个字符串里，如 ClearDark / Default / Dark。
    private func updateAppIcon() {
        let iconTheme = systemIconTheme()
        // 透明和色调模式都是无彩色的，共用同一组变体
        let isMonochrome = iconTheme.contains("clear") || iconTheme.contains("tint")
        // 深浅只认 AppleInterfaceStyle：AppleIconAppearanceTheme 里的 "Dark"
        // 是样式名的一部分，不跟随外观开关变化（实测切浅色后仍是 ClearDark）
        let isDark = Self.systemPrefersDark()

        let name: String
        if isMonochrome {
            name = isDark ? "AppIconClearDark" : "AppIconClearLight"
        } else {
            name = isDark ? "AppIconDark" : "AppIconLight"
        }

        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return }
        NSApp.applicationIconImage = image
        Debug.log("app icon -> \(name) (theme=\(iconTheme), dark=\(isDark))")
    }

    /// 系统外观是否深色（读全局域，不受 App 自己强制主题影响）
    private static func systemPrefersDark() -> Bool {
        let style = CFPreferencesCopyAppValue(
            "AppleInterfaceStyle" as CFString,
            kCFPreferencesAnyApplication
        ) as? String
        return (style ?? "").lowercased() == "dark"
    }

    /// 主题：跟随系统 / 强制浅色 / 强制深色
    func applyTheme(_ theme: String) {
        switch theme {
        case "dark":  NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default:      NSApp.appearance = nil
        }
    }

    @objc func showPanel() {
        // 没授权也让面板正常弹出，只是降级为按程序归类（面板内有橙色提示）。
        // 这里绝不能弹模态框——runModal 会阻塞主线程，把面板挡在后面。
        panelController.toggle()
    }

    @objc func showAllNotes() {
        Debug.log("showAllNotes")
        mainWindowController.show()
    }

    @objc func grantAccessibility() {
        ContextCapture.requestAccessibility()
        showPermissionHelp()
    }

    @objc func openDataFolder() {
        NSWorkspace.shared.open(Store.shared.dataFolder)
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }

    private func showPermissionHelp() {
        guard !axReminderShown else { return }
        axReminderShown = true

        let alert = NSAlert()
        alert.messageText = "需要「辅助功能」权限"
        alert.informativeText = """
        要认出你在哪个程序的哪份文档里，ContextNotes 需要读取窗口信息。

        打开「系统设置 → 隐私与安全性 → 辅助功能」，
        把 ContextNotes 加进去并勾选，然后重新按 ⌥⌘N。

        另外首次呼出时会询问「自动化」权限（用来读取浏览器地址），允许即可。
        """
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")
        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}

// MARK: - 自检模式

// `ContextNotes --probe` 打印当前前台上下文后退出，用来验证权限与锚点是否正常
if CommandLine.arguments.contains("--probe") {
    let probeApp = NSApplication.shared
    probeApp.setActivationPolicy(.accessory)

    let trusted = ContextCapture.hasAccessibility
    print("辅助功能权限: \(trusted ? "✅ 已授权" : "❌ 未授权（窗口标题和文档路径会拿不到）")")

    let ctx = ContextCapture.capture()
    print("应用:     \(ctx.appName)")
    print("bundleID: \(ctx.bundleID ?? "—")")
    print("窗口标题: \(ctx.windowTitle ?? "—")")
    print("文档路径: \(ctx.documentPath ?? "—")")
    print("网页地址: \(ctx.url ?? "—")")
    print("锚点 key: \(ctx.key)")
    exit(0)
}

// MARK: - 存储自检

// `ContextNotes --selftest` 验证写入/读取/删除回路
if CommandLine.arguments.contains("--selftest") {
    let ctx = NoteContext(
        bundleID: "com.test.selftest",
        appName: "SelfTest",
        windowTitle: "窗口A",
        documentPath: nil,
        url: nil
    )
    let before = Store.shared.notes(for: ctx).count
    guard let note = Store.shared.save(body: "自检写入 \(UUID().uuidString.prefix(8))", color: "yellow", context: ctx) else {
        print("❌ 写入失败")
        exit(1)
    }
    let after = Store.shared.notes(for: ctx).count
    print("写入前 \(before) 条 → 写入后 \(after) 条")
    guard after == before + 1 else {
        print("❌ 存储层异常")
        exit(1)
    }
    print("锚点 key: \(ctx.key)")
    Store.shared.delete(id: note.id)
    let reverted = Store.shared.notes(for: ctx).count
    print("回滚后 \(reverted) 条")
    guard reverted == before else {
        print("❌ 删除异常")
        exit(1)
    }
    print("✅ 存储层正常")
    print("数据文件: \(Store.shared.dataFolder.path)/store.json")
    exit(0)
}

// MARK: - 启动

let app = NSApplication.shared
let delegate = AppDelegate()

// 关键：NSApplication.delegate 是 weak 引用，必须强持有，
// 否则 delegate 会在 run() 之前被回收，启动回调永远不触发。
AppDelegate.retained = delegate
app.delegate = delegate
app.run()
