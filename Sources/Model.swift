import AppKit

// MARK: - 颜色工具

extension NSColor {
    convenience init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        var value: UInt64 = 0
        Scanner(string: s).scanHexInt64(&value)
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green:   CGFloat((value >> 8)  & 0xFF) / 255,
            blue:    CGFloat( value        & 0xFF) / 255,
            alpha: 1
        )
    }

    /// 按比例混入另一种颜色，amount=0 是自身，1 是对方
    func blended(with other: NSColor, amount: CGFloat) -> NSColor {
        guard let a = usingColorSpace(.sRGB), let b = other.usingColorSpace(.sRGB) else { return self }
        return NSColor(
            srgbRed: a.redComponent   + (b.redComponent   - a.redComponent)   * amount,
            green:   a.greenComponent + (b.greenComponent - a.greenComponent) * amount,
            blue:    a.blueComponent  + (b.blueComponent  - a.blueComponent)  * amount,
            alpha:   1
        )
    }
}

// MARK: - 上下文：一次便签"贴"在哪儿

struct NoteContext: Codable, Equatable {
    var bundleID: String?
    var appName: String
    var windowTitle: String?
    var documentPath: String?
    var url: String?

    /// 严格锚点：文档路径 > 网页 URL > 应用+窗口标题 > 仅应用
    /// 这是便签"回到原位"的唯一依据，优先级错了会导致串味。
    var key: String {
        if let p = documentPath, !p.isEmpty { return "doc:" + p }
        if let u = url, !u.isEmpty { return "url:" + u }
        if let t = windowTitle, !t.isEmpty { return "win:" + (bundleID ?? appName) + "|" + t }
        return "app:" + (bundleID ?? appName)
    }

    /// 宽松锚点：只按应用归类，用于"这个 App 里的其他记录"兜底展示
    var appKey: String { "app:" + (bundleID ?? appName) }

    var header: String {
        var s = appName
        if let t = windowTitle, !t.isEmpty, t != appName { s += "  ·  " + t }
        return s
    }

    var detail: String {
        if let p = documentPath, !p.isEmpty { return p }
        if let u = url, !u.isEmpty { return u }
        return appName
    }

    func matches(_ needle: String) -> Bool {
        let hay = [appName, windowTitle ?? "", documentPath ?? "", url ?? ""]
            .joined(separator: " ")
            .lowercased()
        return hay.contains(needle)
    }
}

// MARK: - 便签

struct Note: Codable {
    var id: String
    var body: String
    var createdAt: Date
    var updatedAt: Date
    var context: NoteContext
    /// 便签纸颜色标识，如 "yellow"。旧数据没有这个字段时按默认色处理。
    var color: String?
}

// MARK: - 便签配色

enum NoteColor: String, CaseIterable {
    case yellow, peach, pink, mint, sky, lilac, white

    var hex: String {
        switch self {
        case .yellow: return "#FDF4AE"
        case .peach:  return "#FFD9C0"
        case .pink:   return "#FFD6DF"
        case .mint:   return "#D2EFD6"
        case .sky:    return "#D4E8F8"
        case .lilac:  return "#E4DAF6"
        case .white:  return "#F8F7F2"
        }
    }

    var displayName: String {
        switch self {
        case .yellow: return "柠檬黄"
        case .peach:  return "蜜桃橙"
        case .pink:   return "樱花粉"
        case .mint:   return "薄荷绿"
        case .sky:    return "天空蓝"
        case .lilac:  return "薰衣草"
        case .white:  return "素白"
        }
    }

    var nsColor: NSColor { NSColor(hex: hex) }
}

// MARK: - 外观设置

/// 玻璃材质的可调参数。存在独立文件里，和便签数据分开。
struct Appearance: Codable {
    /// 玻璃浓度：0 = 完全通透，1 = 接近不透明
    var tint: Double = 0.20
    /// NSGlassEffectView 风格：regular（常规）/ clear（通透）
    var style: String = "regular"
    /// 圆角
    var cornerRadius: Double = 0
    /// 外观主题：system / light / dark
    var theme: String = "system"
    /// 上次关闭时的窗口位置与大小
    var frame: Frame?

    struct Frame: Codable {
        var x: Double
        var y: Double
        var w: Double
        var h: Double
    }

    static let minTint: Double = 0
    static let maxTint: Double = 0.95
    static let minWidth: Double = 320
    static let minHeight: Double = 240
}

final class AppearanceStore {
    static let shared = AppearanceStore()

    private let fileURL: URL
    private(set) var value = Appearance()

    private init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ContextNotes", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("appearance.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(Appearance.self, from: data) {
            value = decoded
        }
    }

    func update(_ mutate: (inout Appearance) -> Void) {
        mutate(&value)
        persist()
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

// MARK: - 存储

final class Store {
    static let shared = Store()

    private let fileURL: URL
    private(set) var notes: [Note] = []

    private init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ContextNotes", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("store.json")
        notes = Store.read(fileURL)
    }

    var dataFolder: URL { fileURL.deletingLastPathComponent() }

    private static func read(_ url: URL) -> [Note] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([Note].self, from: data)) ?? []
    }

    private func persist() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(notes) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func notes(for context: NoteContext) -> [Note] {
        notes.filter { $0.context.key == context.key }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func notes(forApp context: NoteContext) -> [Note] {
        notes.filter { $0.context.appKey == context.appKey }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// 一个位置只对应"一张便签"：取该上下文里最新更新的一条
    func note(for context: NoteContext) -> Note? {
        notes.filter { $0.context.key == context.key }
            .max { $0.updatedAt < $1.updatedAt }
    }

    /// 保存这张便签。语义是"覆盖这张纸"，而不是追加日志。
    /// 空内容视为无效保存，直接忽略——避免误清空。
    @discardableResult
    func save(body: String, color: String, context: NoteContext) -> Note? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let existing = notes.filter { $0.context.key == context.key }
        if let first = existing.min(by: { $0.createdAt < $1.createdAt }) {
            // 同一位置如果有多条历史记录，合并成一张纸，保留最早的创建时间
            notes.removeAll { $0.context.key == context.key }
            let merged = Note(
                id: first.id,
                body: trimmed,
                createdAt: first.createdAt,
                updatedAt: Date(),
                context: context,
                color: color
            )
            notes.append(merged)
            persist()
            return merged
        }

        let fresh = Note(
            id: UUID().uuidString,
            body: trimmed,
            createdAt: Date(),
            updatedAt: Date(),
            context: context,
            color: color
        )
        notes.append(fresh)
        persist()
        return fresh
    }

    /// 只改颜色，不动内容
    func updateColor(_ color: String, for context: NoteContext) {
        guard let index = notes.firstIndex(where: { $0.context.key == context.key }) else { return }
        notes[index].color = color
        notes[index].updatedAt = Date()
        persist()
    }

    /// 新建便签时沿用上一次用过的颜色，省得每次都挑
    func lastUsedColor() -> NoteColor {
        guard let latest = notes.max(by: { $0.updatedAt < $1.updatedAt }),
              let raw = latest.color,
              let c = NoteColor(rawValue: raw)
        else { return .yellow }
        return c
    }

    func delete(id: String) {
        notes.removeAll { $0.id == id }
        persist()
    }

    func all() -> [Note] {
        notes.sorted { $0.createdAt > $1.createdAt }
    }

    /// 出现过便签的所有上下文（总面板用）
    func contextsSummarized() -> [(context: NoteContext, count: Int, latest: Date)] {
        var map: [String: (NoteContext, Int, Date)] = [:]
        for n in notes {
            let k = n.context.key
            if var cur = map[k] {
                cur.1 += 1
                cur.2 = max(cur.2, n.createdAt)
                map[k] = cur
            } else {
                map[k] = (n.context, 1, n.createdAt)
            }
        }
        return map.values
            .map { (context: $0.0, count: $0.1, latest: $0.2) }
            .sorted { $0.latest > $1.latest }
    }
}

// MARK: - 时间格式

enum Fmt {
    static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    static let relative: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH:mm"
        return f
    }()

    static func label(for date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "今天 " + relative.string(from: date) }
        if Calendar.current.isDateInYesterday(date) { return "昨天 " + relative.string(from: date) }
        return stamp.string(from: date)
    }
}

// MARK: - 调试日志

enum Debug {
    /// 只有存在 /tmp/contextnotes-debug 标记文件时才写日志
    static var enabled: Bool { FileManager.default.fileExists(atPath: "/tmp/contextnotes-debug") }

    static func log(_ message: String) {
        guard enabled else { return }
        let url = URL(fileURLWithPath: "/tmp/contextnotes.log")
        let line = "\(Date()) \(message)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            handle.closeFile()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - 随主题变的配色

enum Palette {
    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    // 浅色玻璃本身接近白，卡片不能再用白；用极淡的黑压出层次，边框留给高光
    static var cardFill: NSColor { dynamic(light: NSColor.black.withAlphaComponent(0.045),
                                           dark: NSColor.white.withAlphaComponent(0.09)) }
    static var cardHover: NSColor { dynamic(light: NSColor.black.withAlphaComponent(0.08),
                                            dark: NSColor.white.withAlphaComponent(0.16)) }
    static var cardBorder: NSColor { dynamic(light: NSColor.white.withAlphaComponent(0.70),
                                             dark: NSColor.white.withAlphaComponent(0.10)) }
    static var pillFill: NSColor { dynamic(light: NSColor.black.withAlphaComponent(0.035),
                                           dark: NSColor.white.withAlphaComponent(0.10)) }
    static var pillBorder: NSColor { dynamic(light: NSColor.white.withAlphaComponent(0.65),
                                             dark: NSColor.white.withAlphaComponent(0.12)) }
    /// 深色模式的压底：玻璃会采样背后内容，白底文档上光靠 tintColor 压不黑
    static var scrim: NSColor { dynamic(light: .clear, dark: NSColor.black.withAlphaComponent(0.55)) }
}

// MARK: - Liquid Glass 工厂

/// 两个窗口共用同一套玻璃材质，保证视觉一致
/// 深色压底层：随主题自动黑/透明
final class ScrimView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        Palette.scrim.setFill()
        bounds.fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

enum Glass {
    /// 返回玻璃背景和真正该放内容的那一层
    static func makeBackground() -> (background: NSView, container: NSView) {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = 12

            let container = NSView()
            let scrim = ScrimView()
            scrim.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(scrim)
            NSLayoutConstraint.activate([
                scrim.topAnchor.constraint(equalTo: container.topAnchor),
                scrim.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                scrim.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                scrim.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
            glass.contentView = container
            return (glass, container)
        }

        let fx = NSVisualEffectView()
        fx.material = .sidebar
        fx.blendingMode = .behindWindow
        fx.state = .active
        return (fx, fx)
    }

    static func apply(_ look: Appearance, to background: NSView, radius override: CGFloat? = nil) {
        let radius = override ?? CGFloat(look.cornerRadius)
        if #available(macOS 26.0, *), let glass = background as? NSGlassEffectView {
            glass.style = (look.style == "clear") ? .clear : .regular
            glass.cornerRadius = radius
            glass.tintColor = Palette.dynamic(light: .white, dark: .black)
                .withAlphaComponent(CGFloat(look.tint))
        } else if let fx = background as? NSVisualEffectView {
            fx.material = (look.style == "clear") ? .underWindowBackground : .sidebar
        }
    }

    /// 圆角填充块，用来做搜索框底、卡片底
    static func roundedFill(_ color: NSColor, radius: CGFloat, border: NSColor? = nil) -> NSView {
        RoundedFillView(fill: color, radius: radius, border: border)
    }
}

final class RoundedFillView: NSView {
    private let fill: NSColor
    private let radius: CGFloat
    private let border: NSColor?

    init(fill: NSColor, radius: CGFloat, border: NSColor?) {
        self.fill = fill
        self.radius = radius
        self.border = border
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        fill.setFill()
        path.fill()
        if let border {
            border.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }
}
