import AppKit
import ApplicationServices

/// 识别"用户现在在哪个程序的哪份文档里"。
///
/// 分四层，从强到弱：
///   1. AXDocument       —— 文档类应用直接给出文件绝对路径（最强）
///   2. 浏览器 URL        —— 通过 AppleScript 问前台浏览器要当前标签页地址
///   3. 窗口标题          —— AX 拿聚焦窗口的 title（绝大多数应用都有）
///   4. 仅应用             —— 兜底，退化成"这个 App 的便签"
///
/// 前三层任一命中就够用，全落空也不会崩，只是便签粒度变粗。
enum ContextCapture {

    /// 记录最近一个"非本应用"的前台应用，避免用户从便签面板点回原应用时抓到自己
    static var lastExternalApp: NSRunningApplication?

    static func capture(preferring preferred: NSRunningApplication? = nil) -> NoteContext {
        var front = NSWorkspace.shared.frontmostApplication

        // 如果前台变成了我们自己的面板，回溯到真正的外部应用
        if front?.bundleIdentifier == Bundle.main.bundleIdentifier {
            front = preferred ?? lastExternalApp ?? front
        }

        let appName = front?.localizedName ?? "未知程序"
        let bundleID = front?.bundleIdentifier
        let pid = front?.processIdentifier ?? 0

        var title: String?
        var docPath: String?

        if pid > 0, AXIsProcessTrusted() {
            let appEl = AXUIElementCreateApplication(pid)

            if let windowEl = focusedWindow(of: appEl) {
                title = stringAttribute(windowEl, kAXTitleAttribute)
                docPath = stringAttribute(windowEl, kAXDocumentAttribute)
            }

            // 有些应用（如预览、Xcode）文档挂在主窗口而非聚焦窗口上
            if docPath == nil {
                docPath = mainWindowDocument(of: appEl)
            }
        }

        let url = browserURL(bundleID: bundleID)

        return NoteContext(
            bundleID: bundleID,
            appName: appName,
            windowTitle: title,
            documentPath: docPath,
            url: url
        )
    }

    // MARK: - AX 细节

    private static func axCopy(_ element: AXUIElement, _ attr: String) -> CFTypeRef? {
        var ref: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attr as CFString, &ref)
        return err == .success ? ref : nil
    }

    private static func stringAttribute(_ element: AXUIElement, _ attr: String) -> String? {
        guard let value = axCopy(element, attr) else { return nil }
        guard let s = value as? String else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func focusedWindow(of appEl: AXUIElement) -> AXUIElement? {
        guard let ref = axCopy(appEl, kAXFocusedWindowAttribute) else { return nil }
        return (ref as! AXUIElement)
    }

    private static func mainWindowDocument(of appEl: AXUIElement) -> String? {
        guard let ref = axCopy(appEl, kAXMainWindowAttribute) else { return nil }
        let win = (ref as! AXUIElement)
        return stringAttribute(win, kAXDocumentAttribute)
    }

    // MARK: - 浏览器 URL

    private static let browserScripts: [String: String] = [
        "com.apple.Safari":              "\"Safari\"",
        "com.apple.SafariTechnologyPreview": "\"Safari Technology Preview\"",
        "com.google.Chrome":             "\"Google Chrome\"",
        "com.google.Chrome.canary":      "\"Google Chrome Canary\"",
        "com.microsoft.edgemac":         "\"Microsoft Edge\"",
        "com.brave.Browser":             "\"Brave Browser\"",
        "company.thebrowser.Browser":    "\"Arc\"",
        "org.vivaldi.Vivaldi":           "\"Vivaldi\"",
        "com.operasoftware.Opera":       "\"Opera\"",
    ]

    private static func browserURL(bundleID: String?) -> String? {
        guard let id = bundleID, let appExpr = browserScripts[id] else { return nil }
        let script = "tell application \(appExpr) to get URL of active tab of front window"
        // Safari 用 "current tab"，其余 Chromium 系用 "active tab"
        let safariScript = "tell application \(appExpr) to get URL of current tab of front window"
        let primary = id.hasPrefix("com.apple.Safari") ? safariScript : script

        if let out = runOsascript(primary) { return out }
        // 交叉兜底：Chromium 系有时也接受 current tab 写法，反之亦然
        return runOsascript(primary == script ? safariScript : script)
    }

    /// 带超时的 osascript 调用。
    /// 首次调用会弹"自动化"授权框，此时会超时并降级到窗口标题——可接受。
    private static func runOsascript(_ source: String, timeout: TimeInterval = 1.0) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", source]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice

        do { try proc.run() } catch { return nil }

        let deadline = Date().addingTimeInterval(timeout)
        while proc.isRunning && Date() < deadline {
            usleep(20_000)
        }
        if proc.isRunning {
            proc.terminate()
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let raw = String(data: data, encoding: .utf8) else { return nil }
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // osascript 失败时会往 stdout 写 "missing value" 之类
        if s.isEmpty || s == "missing value" { return nil }
        return s
    }

    // MARK: - 权限

    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    /// 触发系统"辅助功能"授权引导（只会弹一次，之后需手动到系统设置里勾选）
    @discardableResult
    static func requestAccessibility() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
