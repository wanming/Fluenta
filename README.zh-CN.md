# Inklet

[English](README.md) | [简体中文](README.zh-CN.md)

官网：[gitinklet.app](https://gitinklet.app)

**Turn rough thoughts into clear text.**

**Inklet** 是一款 macOS 写作助手，可以把你输入、粘贴或说出的想法整理成清晰自然的文字，并直接插回正在使用的应用。

你可以用全局快捷键打开写作浮窗，然后在同一份可编辑原文草稿中输入、粘贴或听写。实时听写已合并到写作助手，转写完成后会停留在草稿里，等待你检查和编辑。

## 演示

观看演示视频：[Inklet on YouTube](https://www.youtube.com/watch?v=F5wmFruo0a4)。

## 安装

GitHub Releases 是 Inklet 唯一支持的发布渠道。请从 [GitHub Releases](https://github.com/wanming/Inklet/releases) 下载最新已签名并完成 Apple 公证的 DMG，打开后把 Inklet 复制到 `/Applications`。

也可以使用下面的安装脚本。安装脚本会下载最新 GitHub Releases DMG 及 checksum，验证 DMG 结构、checksum、Gatekeeper、bundle identifier、Hardened Runtime、effective entitlements 和 App 签名，再把 Inklet 复制到 `/Applications`。

```bash
curl -fsSL https://raw.githubusercontent.com/wanming/Inklet/main/scripts/install.sh | bash
```

## 首次设置

1. 从 Applications 文件夹打开 Inklet。需要运行源码构建时，请在仓库根目录执行 `scripts/run-local-app.sh`，然后使用 `/Applications/Inklet Local.app`。
2. 点击菜单栏里的 Inklet 图标，打开 Settings。
3. 按 macOS 提示授予 Accessibility 权限。Inklet 用这一个通用权限读取选区、执行已配置的复制备用流程、回到上一个应用并粘贴确认后的结果。系统设置打开期间 Inklet 会留在后台；关闭系统设置后 Inklet 会返回 General 设置页。
4. 在 General 中填写 OpenAI API key。Inklet 会用这一把 key 处理写作、实时听写、选区翻译和发音。
5. 在 Writing Assistant 中配置模型、写作快捷键、生成参数、Prompt 模式、听写长按快捷键和麦克风。高级听写只提供一次恢复所用的端点和模型；实时模型由 Inklet 固定。
6. 可选：在 Selection Assistant 中配置翻译语言、强制取词模式、AI 发音声音和发音速度，并在设置中试听该声音。
7. 第一次有效长按听写快捷键时授予 Microphone 权限。只打开 Inklet、查看 Settings，或在原文编辑器之外按快捷键都不会请求权限。

## 日常使用

文字输入流程：

1. 在任意应用里聚焦一个文本框。
2. 按 `Option+Space`。
3. 用模糊搜索查找 Prompt 模式（例如 `ts` 可以匹配 `To Chinese Summary`），用 `↑` / `↓` 高亮，然后按 `Tab` 或 `Enter` 确认。
4. 输入或粘贴一段草稿。
5. 按 `Enter` 让 Inklet 处理文本。
6. 再按一次 `Enter` 插入结果。

听写流程：

1. 用 `Option+Space` **打开写作助手**。
2. **确认一个 Prompt 模式**。模式选择器和结果编辑器中不能开始听写。
3. **把光标放入原文草稿，或选中要替换的文本。** 听写会在光标处插入，或替换选区。
4. **长按已配置的听写快捷键**（默认 Right Option）并正常说话，转写草稿会原位更新。短按不会执行任何操作。如果实时连接失败，继续长按并说话，Inklet 会保留一份临时恢复录音。
5. **松开以完成转写**。Inklet 最多进行一次文件转写恢复尝试，并在听写会话结束时删除临时录音。
6. 检查并编辑听写草稿。听写本身不会运行 Prompt 模式，也不会把文本插入其他 App。
7. **准备好后再按 Return** 运行已确认的 Prompt 模式；只有要插入结果时才再按一次 Return。

听写快捷键仅在原文编辑器内生效，并且只支持长按。你可以在 Settings 中把修饰键改为 Right Command、Left Option、Left Command，或直接关闭。Escape、焦点丢失、关闭浮窗或开始新的原文会话都会取消听写并恢复原草稿。

## 功能

- 使用全局 macOS 快捷键打开。默认是 `Option+Space`。
- 在写作助手原文编辑器处于活动状态时，长按 modifier key 快捷键，把实时听写写入草稿。默认是 Right Option。
- 选中文本并短暂停顿后显示选区动作，可快速翻译、自定义 Translate prompt、使用 AI 发音；翻译结果窗口可调整大小并记住上次尺寸，也会为重复翻译提供 7 天本地缓存。
- 超过 1,500 个字符的选中文本会被忽略，避免误选整页时触发。
- 可直接播放选中文本，也可在翻译结果里分别播放原文和译文。
- 内置文本处理模式：
  - To Simple and Correct English
  - To Chinese Summary
  - Voice Cleanup
- 把生成结果插回之前聚焦的应用。
- 使用与应用无关、Accessibility 优先的通用选区流程。自动选区动作先通过 macOS Accessibility 读取；只有强制取词设置允许时，才进入按设置启用的临时剪贴板备用读取。每次读取都绑定到捕获的来源进程；来源退出或失去前台焦点时会取消。
- 默认关闭模拟 `Command+C`。菜单复制仍是安全的强制取词备用方式；对于没有可用复制菜单的 App，可以显式开启模拟复制这一高级备用选项，但它可能干扰游戏、远程桌面或虚拟机。
- 临时剪贴板读取会串行执行。只有同一次读取仍持有已观察到的复制结果时，Inklet 才恢复之前的快照；较新的剪贴板内容优先。双击复制触发是被动流程：它只读取用户已经完成的复制，不会再发一次合成复制，也不会恢复更旧的剪贴板数据。右键点击保留原生行为，不会开始选区读取。
- 不包含浏览器专用的选区代码，也不会请求浏览器 Automation。Chrome、Safari、Edge 和原生 App 使用同一条通用流程。
- 可以编辑 Prompt 模式、OpenAI 模型、timeout、写作快捷键、听写长按快捷键、麦克风、恢复转写端点和模型、选区翻译语言、选区 Translate prompt、强制取词模式、模拟复制权限、AI 发音声音和 AI 发音速度。
- 在本地 History 中查看成功的写作和选区结果，连续重复项会自动合并，原文/结果文本可选择，可一键复制结果或清空全部历史；旧版 Voice History 仍可读取。
- 使用一把共享的 OpenAI API key 处理写作、实时听写、选区翻译和发音。
- 提供英文和中文应用界面。

## 当前状态

Inklet 是早期 MVP。当前仓库包含：

- macOS app 和核心写作引擎的 Swift Package。
- 带写作 popover 和设置窗口的菜单栏应用。
- Provider adapters 和配置存储。
- 核心行为的单元测试。
- 手动测试说明：[docs/manual-test-checklist.md](docs/manual-test-checklist.md)。

## 系统要求

- macOS 14 或更新版本。
- Swift 6 toolchain。
- 推荐安装完整 Xcode，以获得 XCTest 支持。
- Accessibility 权限，用于通用选区读取、按设置启用的复制备用流程、回到上一个应用并粘贴生成结果。
- Microphone 权限，仅在有效长按听写快捷键时用于实时听写。
- 一个 OpenAI API key。

## 从源码构建和运行

在仓库根目录运行：

```bash
swift build
scripts/run-local-app.sh
```

日常手动测试请从任意 worktree 使用 `scripts/run-local-app.sh`。它会安装并打开稳定的 `/Applications/Inklet Local.app` 身份，让 macOS 的 Accessibility 和 Keychain 授权可以跨 rebuild 复用。

运行测试：

```bash
swift test
```

如果测试因为 `XCTest` 不可用而失败，请安装完整 Xcode，而不是只安装 Command Line Tools。

## 快捷键

- `Option+Space`：打开写作 popover。
- `Right Option`：写作助手原文编辑器处于活动状态时长按听写。可在 Settings 中修改修饰键或关闭；短按始终不执行操作。
- 模式启动器中的 `↑` / `↓`：在按模糊匹配度排序的 Prompt 模式之间移动高亮。
- 模式启动器中的 `Tab`、`Return` 或小键盘 `Enter`：确认高亮的 Prompt 模式并聚焦源文本编辑器。输入法正在组合文字时，Return 仍用于确认文字或候选项；配合 Command、Shift、Option 或 Control 的 Return 不会确认模式。
- 编辑器中的 `Enter`：处理源文本；插入由当前模式生成的结果；如果可见结果由之前的模式生成，则用刚确认的新模式重新生成。
- `Command+Enter`：不调用模型，直接插入原文。
- `Command+Up` / `Command+Down`：切换可见 prompt modes。
- `Escape`：每按一次只返回一层，依次从结果回到源文本编辑器、模式启动器，再关闭 popover。处理文本期间按下会取消生成并停留在编辑器。
- `Command+,`：Inklet 激活时打开 Settings。

搜索不区分大小写和变音符号，并支持按顺序匹配字符。完全匹配和前缀匹配获得最高加权；连续、词首、更靠前及间隔更紧密的匹配通常排名更高。

模式启动器打开时，如果上次确认的 Prompt 模式仍然可见，就会高亮该模式。单击只会高亮模式，双击会确认；返回模式启动器时会保留当前草稿和结果。

## 仓库结构

```text
Sources/InkletApp/       macOS app, popover UI, settings UI, menu bar coordination
Sources/InkletCore/      core config, providers, prompts, hotkeys, insertion, state machine
Tests/InkletCoreTests/   unit tests for core behavior
docs/                    手动测试说明和隐私政策
```

## 开发说明

- Provider 行为应保持有聚焦的单元测试覆盖。
- 发布用户可见的 app 改动前，请使用 [docs/manual-test-checklist.md](docs/manual-test-checklist.md)。
- 日常手动测试 app 时使用 `scripts/run-local-app.sh`，不要直接运行 SwiftPM 可执行文件或 `open dist/...`，这样本机 Accessibility 和 Keychain 授权会绑定到同一个稳定 app 身份。
- 剪贴板和 Accessibility 流程是核心体验，需要谨慎处理。
- 项目仍处于 MVP 阶段，README 应描述当前代码已经支持的能力，而不是未来计划。

## 本地存储与升级

正式版与本地 QA 版使用按 bundle 标识符隔离的存储，不共享设置、History、翻译缓存、诊断文件或 Keychain 凭据：

- 正式版 Application Support：`~/Library/Application Support/com.tomwan.inklet/`
- 本地版 Application Support：`~/Library/Application Support/com.tomwan.inklet.local/`
- 正式版偏好设置：`~/Library/Preferences/com.tomwan.inklet.plist`
- 本地版偏好设置：`~/Library/Preferences/com.tomwan.inklet.local.plist`
- 正式版 Keychain service：`Inklet.ProviderAPIKey`
- 本地版 Keychain service：`Inklet.Local.ProviderAPIKey`

从旧版 sandbox 构建升级后的第一次启动中，Inklet 会自动复制已识别的旧版偏好设置、把 provider API keys 写入对应 Keychain service，并把 History 复制到当前 bundle 的存储中。迁移不会删除或修改旧版来源，因此旧数据仍可用于回滚或恢复。可丢弃的翻译缓存不会迁移。

如果 macOS 阻止自动访问对应的旧容器，Settings 会持续提供**导入旧数据…**操作。辅助导入只接受当前正式版或本地版对应的准确旧版 `Data` 文件夹，只在当前文件选择授权有效期间读取，并且不会保存永久访问 bookmark。

## 隐私

- Inklet 使用你配置的 OpenAI API key 调用 OpenAI，处理写作、实时听写、选区翻译和发音。
- 长按听写快捷键期间，活动麦克风音频会直接流式发送到 OpenAI Realtime 转写服务。Inklet 还会保存一份临时本地恢复录音，仅在需要时用于一次恢复尝试，并在会话结束时删除。
- OpenAI API key 存储在你的 Mac 本地。
- Inklet 使用 Accessibility 权限完成通用选区读取、按设置启用的复制备用流程、回到上一个应用并粘贴文本。
- Inklet 只在写作助手原文编辑器内有效长按听写快捷键时使用 Microphone 权限。听写完成后仍停留在可编辑草稿，不会插入其他 App。
- Inklet 会临时使用剪贴板完成插入和已配置的强制取词备用读取。强制取词仅在 Inklet 的临时复制内容仍是当前内容时恢复原剪贴板，不会覆盖之后发生的外部剪贴板变化。
- Inklet 会把成功的写作和选区原文/结果作为本地 History 保存，直到你在 Settings 中清空；连续重复项会自动跳过。未经处理的听写草稿不会创建 History；已有的旧版 Voice 条目仍可在本机读取。
- 选区动作会捕获来源 App 和选区位置，在读取前和读取期间验证来源，然后通过 Accessibility 读取该 App 的当前选区。如果 Accessibility 没有返回选中文本，设置中的强制取词模式可以短暂调用菜单复制，并通过上面所述的受保护剪贴板事务读取复制出的文本。模拟 `Command+C` 默认关闭，只有显式开启高级选项后才会运行。你可以在设置中关闭强制取词。此流程不会发送针对浏览器的 Apple Events，也不会请求浏览器 Automation。选中文本后快速按两次 `Command+C`，会显式读取你已经完成的复制。Inklet 不会保存仅被选中的文本；只有成功完成的动作会进入本地 History。
- Selection Assistant 会把成功的翻译结果用哈希缓存键在本地缓存 7 天，以加速重复翻译。
- 当本地没有可用缓存时，Selection Assistant 翻译会把选中文本和自定义 Translate 指令发送到 OpenAI；AI 发音会把选中文本发送到 OpenAI。
- Inklet 最多每天从 `models.dev` 获取一次公开模型目录。该请求不包含你的文本、音频、API keys 或应用设置。
- 除非你信任 OpenAI 的数据处理政策，否则不要发送私密文本或音频。

## 贡献

请查看 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 安全

漏洞报告和敏感数据说明请查看 [SECURITY.md](SECURITY.md)。

## 许可证

Inklet 使用 [MIT License](LICENSE) 发布。
第三方许可说明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
