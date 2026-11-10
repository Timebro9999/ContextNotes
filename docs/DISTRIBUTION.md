# 分发与上架

本文说明两条分发路径的现状、必须改动的地方，以及各自的代价。
标注 **[已验证]** 的结论来自本机实测或官方文档；标注 **[待验证]** 的需要真实沙盒环境跑一次才能确定。

---

## 一、GitHub Releases（推荐）

这是这类工具的主流路径：不受沙盒限制，功能完整。

### 现状

- 本仓库用**自签名证书**签名，只够本机使用
- 别人下载后会看到「无法打开，因为无法验证开发者」

### 要对外分发，需要

1. **加入 Apple Developer Program**（99 美元/年）——没有免费替代
2. 用 **Developer ID Application** 证书签名
3. 开启 Hardened Runtime（`--options runtime`）
4. **公证（notarization）**：`xcrun notarytool submit`，通过后 `xcrun stapler staple`

```bash
# 示意，需要真实证书
codesign --force --options runtime --timestamp \
         --sign "Developer ID Application: Your Name (TEAMID)" ContextNotes.app
ditto -c -k --keepParent ContextNotes.app ContextNotes.zip
xcrun notarytool submit ContextNotes.zip --keychain-profile "AC_PASSWORD" --wait
xcrun stapler staple ContextNotes.app
```

通过公证后，用户下载双击即可打开，无需右键绕过。

### 还可以做

- 打 Homebrew Cask：`brew install --cask contextnotes`
- GitHub Actions 自动构建 + 公证 + 发布 Release

---

## 二、Mac App Store

### 硬门槛 [已验证]

Apple 官方文档明确：*"To distribute your macOS app through the Mac App Store, you must enable the App Sandbox capability."*

沙盒不是可选项。这直接冲击本项目的核心机制。

### 逐项影响

| 现有实现 | 沙盒下是否可行 | 必须改成 |
|---|---|---|
| `AXUIElementCreateApplication` 读其他 App 的窗口标题/文档路径 | **[待验证]** 大概率不可行 | 见下方分析 |
| 用 `/usr/bin/osascript` 子进程问浏览器要 URL | **不可行** | 换成 `NSAppleScript` + `com.apple.security.automation.apple-events` 权限 |
| 写 `~/Library/LaunchAgents/*.plist` 做登录自启 | **不可行** | 换成 `SMAppService.mainApp.register()` |
| 全局热键（Carbon） | 可行 | — |
| `NSStatusItem` 菜单栏图标 | 可行 | — |
| 数据放 `~/Library/Application Support/ContextNotes` | 可行但位置变 | 自动落到沙盒容器内 |

### 关键疑点：辅助功能 API

本机 `/System/Library/Sandbox/Profiles/application.sb` 中，与 accessibility 相关的放行只有：

```
(global-name "com.apple.accessibility.voices")
```

这是**语音合成**，不是 AX 检查服务。也就是说默认沙盒配置里没有放行跨进程 UI 检查。

要突破只能用 `com.apple.security.temporary-exception.mach-lookup.global-name`
这类**临时例外** entitlement——而 Apple 对临时例外的审核极严，通常要求证明无替代方案，
审核周期长且不保证通过。

**结论：这一项必须做一次真实沙盒 spike 才能定论。** 做法：

1. 建一个最小探针 App，带 `com.apple.security.app-sandbox = true` 签名
2. 申请辅助功能权限
3. 尝试 `AXUIElementCreateApplication(前台 pid)` 并读 `kAXTitleAttribute`
4. 看返回的是数据还是 `kAXErrorAPIDisabled` / `kAXErrorCannotComplete`

如果沙盒下 AX 完全不可用，**这个产品形态就无法进 MAS**，因为它们是一体的：

- 没有窗口标题和文档路径，就没有"回到同一处"这个核心能力
- 退化成"只按 App 归类"的普通便签，价值大幅下降

### 即使技术上可行，还有审核风险

- 应用会读取**所有前台应用的窗口标题和文档路径**并持久化。
  这属于对他人数据的广泛采集，审核依据 5.1.1（数据收集与存储）会追问用途与最小化
- 需要充分的隐私说明、用途描述，以及"为什么非读不可"的论证
- 辅助功能权限在 MAS 应用上属于"核心功能依赖"，可以申请，但描述必须准确

### 上架还得准备

- Apple Developer Program 会籍
- App Store Connect 应用记录、截图（多尺寸）、隐私政策 URL
- 分类、年龄分级、审核备注（说明为什么要辅助功能权限）

---

## 三、务实建议

| 目标 | 方案 |
|---|---|
| 给自己和少数人用 | 现状即可（自签名） |
| 公开给别人下载 | **Developer ID + 公证 + GitHub Releases**，99 美元/年，工作量约一天 |
| 进 App Store | 先做沙盒 spike。若 AX 不可用，需重新设计核心（例如改为**只标注浏览器网页**或**基于截屏 + OCR**的替代锚点），那基本是另一个产品 |

**推荐顺序：先走 Releases。** 它不需要改动产品逻辑，只需要签名和公证流程。
App Store 是另一条产品线，不是打包问题。
