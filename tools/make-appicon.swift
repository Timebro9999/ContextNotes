import AppKit

// MARK: - 图标样式

/// 对应系统设置「图标与小组件样式」：
///   默认 → light      深色 → dark
///   透明 + 浅色 → clearLight    透明 + 深色 → clearDark
enum IconStyle {
    case light, dark, clearLight, clearDark

    var isClear: Bool { self == .clearLight || self == .clearDark }
    var isDarkGround: Bool { self == .dark || self == .clearDark }
    var fileName: String {
        switch self {
        case .light:      return "AppIconLight"
        case .dark:       return "AppIconDark"
        case .clearLight: return "AppIconClearLight"
        case .clearDark:  return "AppIconClearDark"
        }
    }
}

/// 画一张图标
func drawIcon(in size: CGFloat, style: IconStyle) -> NSBitmapImageRep {
    let px = Int(size)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { fatalError("bitmap") }
    rep.size = NSSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    let s = size
    let inset = s * 0.055
    let bgRect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = bgRect.width * 0.2237
    let squircle = NSBezierPath(roundedRect: bgRect, xRadius: radius, yRadius: radius)

    // ---- 背景 ----
    switch style {
    case .light:
        NSGradient(
            starting: NSColor(srgbRed: 0.49, green: 0.66, blue: 1.00, alpha: 1),
            ending:   NSColor(srgbRed: 0.20, green: 0.31, blue: 0.92, alpha: 1)
        )?.draw(in: squircle, angle: -90)

    case .dark:
        // 黑底 + 淡蓝字形，参考系统深色图标的调性
        NSColor(srgbRed: 0.045, green: 0.055, blue: 0.072, alpha: 1).setFill()
        squircle.fill()

    case .clearLight:
        // 透明 + 浅色：极薄白雾，纸片靠自身亮度立住
        NSColor.white.withAlphaComponent(0.10).setFill()
        squircle.fill()
        NSColor.white.withAlphaComponent(0.42).setStroke()
        squircle.lineWidth = max(1.4, s * 0.005)
        squircle.stroke()

    case .clearDark:
        // 与深色一致：黑底 + 淡蓝字形
        NSColor(srgbRed: 0.045, green: 0.055, blue: 0.072, alpha: 1).setFill()
        squircle.fill()
    }

    // 顶部高光（透明模式不要，会把玻璃压成实心）
    if !style.isClear && !style.isDarkGround {
        NSGraphicsContext.saveGraphicsState()
        squircle.addClip()
        let glow = NSRect(x: bgRect.minX, y: bgRect.midY,
                          width: bgRect.width, height: bgRect.height * 0.55)
        NSGradient(
            starting: NSColor.white.withAlphaComponent(0.28),
            ending: NSColor.white.withAlphaComponent(0)
        )?.draw(in: glow, angle: -90)
        NSGraphicsContext.restoreGraphicsState()
    }

    // ---- 纸张 ----
    let paperW = s * 0.43, paperH = s * 0.51
    let paperRect = NSRect(x: (s - paperW) / 2, y: (s - paperH) / 2 - s * 0.015,
                           width: paperW, height: paperH)
    let paperRadius = s * 0.035

    ctx.saveGState()
    ctx.translateBy(x: s / 2, y: s / 2)
    ctx.rotate(by: -7 * .pi / 180)
    ctx.translateBy(x: -s / 2, y: -s / 2)

    let shadow = NSShadow()
    if !style.isDarkGround {
        shadow.shadowColor = NSColor.black.withAlphaComponent(style.isClear ? 0.35 : 0.28)
        shadow.shadowBlurRadius = s * 0.045
        shadow.shadowOffset = NSSize(width: 0, height: -s * 0.018)
        shadow.set()
    }

    let paper = NSBezierPath(roundedRect: paperRect, xRadius: paperRadius, yRadius: paperRadius)
    NSColor.white.setFill()
    paper.fill()

    NSGraphicsContext.saveGraphicsState()
    paper.addClip()
    let paperTop: NSColor
    let paperBottom: NSColor
    switch style {
    case .light:
        paperTop = NSColor(white: 1.0, alpha: 1)
        paperBottom = NSColor(srgbRed: 0.90, green: 0.93, blue: 0.99, alpha: 1)
    case .dark:
        paperTop = NSColor(srgbRed: 0.79, green: 0.88, blue: 0.92, alpha: 1)
        paperBottom = NSColor(srgbRed: 0.69, green: 0.80, blue: 0.86, alpha: 1)
    case .clearLight:
        paperTop = NSColor(white: 1.0, alpha: 0.97)
        paperBottom = NSColor(white: 0.88, alpha: 0.92)
    case .clearDark:
        paperTop = NSColor(srgbRed: 0.79, green: 0.88, blue: 0.92, alpha: 1)
        paperBottom = NSColor(srgbRed: 0.69, green: 0.80, blue: 0.86, alpha: 1)
    }
    NSGradient(starting: paperTop, ending: paperBottom)?.draw(in: paperRect, angle: -90)

    // ---- 三行字 ----
    let lines: [(CGFloat, CGFloat)] = [(0.86, 1.0), (0.62, 0.86), (0.38, 0.62)]
    let lineH = s * 0.030
    let textLeft = paperRect.minX + s * 0.055

    for (i, spec) in lines.enumerated() {
        let w = paperW * 0.62 * spec.0
        let y = paperRect.maxY - paperRect.height * (0.30 + CGFloat(i) * 0.155)
        let bar = NSRect(x: textLeft, y: y, width: w, height: lineH)

        let color: NSColor
        switch style {
        case .light:
            color = (i == lines.count - 1)
                ? NSColor(srgbRed: 1.0, green: 0.44, blue: 0.26, alpha: 1)
                : NSColor(srgbRed: 0.62, green: 0.68, blue: 0.78, alpha: spec.1)
        case .dark:
            color = NSColor(srgbRed: 0.045, green: 0.055, blue: 0.072, alpha: 0.62 * spec.1)
        case .clearLight:
            // 无彩色模式：不留橙色
            color = NSColor(white: 0.32, alpha: 0.40 * spec.1)
        case .clearDark:
            color = NSColor(srgbRed: 0.045, green: 0.055, blue: 0.072, alpha: 0.62 * spec.1)
        }
        color.setFill()
        NSBezierPath(roundedRect: bar, xRadius: lineH / 2, yRadius: lineH / 2).fill()
    }

    NSGraphicsContext.restoreGraphicsState()
    ctx.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// MARK: - 输出

let specs: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

func write(_ rep: NSBitmapImageRep, to path: String) {
    guard let data = rep.representation(using: .png, properties: [:]) else { return }
    try? data.write(to: URL(fileURLWithPath: path))
}

// 默认（蓝色）打包成 icns，供 Finder 使用
let iconSet = URL(fileURLWithPath: "Assets/AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconSet, withIntermediateDirectories: true)
for (name, px) in specs {
    write(drawIcon(in: CGFloat(px), style: .light),
          to: iconSet.appendingPathComponent("\(name).png").path)
}

// 四套运行时图 512px
for style in [IconStyle.light, .dark, .clearLight, .clearDark] {
    write(drawIcon(in: 512, style: style), to: "Assets/\(style.fileName).png")
}

// 设计预览
for style in [IconStyle.light, .dark, .clearLight, .clearDark] {
    write(drawIcon(in: 1024, style: style), to: "design/appicon-\(style.fileName).png")
}

print("已生成：icns（浅色）+ \(IconStyle.light.fileName)/.dark/.clearLight/.clearDark 四套运行时图")
