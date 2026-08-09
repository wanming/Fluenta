# Inklet

[English](README.md) | [简体中文](README.zh-CN.md)

官网：[gitinklet.app](https://gitinklet.app)

**Turn rough thoughts into clear text.**

**Inklet** 是一款 macOS 写作助手，可以把你输入、粘贴或说出的想法整理成清晰自然的文字，并直接插回正在使用的应用。

你可以用全局快捷键打开一个小型写作窗口，也可以用语音快捷键录入一小段话。Inklet 能改写、总结、清理语音转写内容，并把结果插入回原来的文本框。

## 演示

观看演示视频：[Inklet on YouTube](https://www.youtube.com/watch?v=F5wmFruo0a4)。

## 安装

Mac App Store：即将上线。

你也可以从 [GitHub Releases](https://github.com/wanming/Inklet/releases) 下载最新已签名并公证的 DMG，或使用下面的安装脚本。脚本会下载最新 DMG，校验 checksum，检查 Gatekeeper 和 App 签名，然后复制 Inklet 到 `/Applications`。

```bash
curl -fsSL https://raw.githubusercontent.com/wanming/Inklet/main/scripts/install.sh | bash
```

## 首次设置

1. 从 Applications 文件夹打开 Inklet。从源码运行时，请使用 `scripts/run-local-app.sh` 构建、安装并启动稳定的 `/Applications/Inklet Local.app`。
2. 点击菜单栏里的 Inklet 图标，打开 Settings。
3. 按 macOS 提示授予 Accessibility 权限。Inklet 需要这个权限来回到上一个应用并粘贴结果。系统设置打开期间 Inklet 会留在后台；关闭系统设置后 Inklet 会返回 General 设置页。
4. 在 General 中填写 OpenAI API key。Inklet 会用这一把 key 处理写作、语音转写、选区翻译和发音。
5. 在 Write Assistant 中配置模型、写作快捷键、生成参数和 prompt modes。
6. 可选：在 Voice Write Assistant 中配置麦克风、speech preset、语音快捷键、录音方式和转写后的处理方式。
7. 可选：在 Selection Assistant 中配置翻译语言、强制取词模式、AI 发音声音和发音速度，并在设置中试听该声音。
8. 第一次使用语音输入时，请授予 Microphone 权限。

## 日常使用

文字输入流程：

1. 在任意应用里聚焦一个文本框。
2. 按 `Option+Space`。
3. 搜索 Prompt 模式，用 `↑` / `↓` 高亮，然后按 `Tab` 确认。
4. 输入或粘贴一段草稿。
5. 按 `Enter` 让 Inklet 处理文本。
6. 再按一次 `Enter` 插入结果。

语音输入流程：

1. 在任意应用里聚焦一个文本框。
2. 按住 Right Option，用选中的麦克风开始录音。
3. 说一小段话。
4. 松开 Right Option 停止录音。
5. Inklet 会转写音频，然后根据 Voice 设置使用整理模式、每次询问 prompt mode，或直接插入原始转写。

默认语音快捷键是 Right Option，默认录音方式是按住录音。你可以在 Settings 中改成 Right Command、Left Option、Left Command，或直接关闭；录音方式也可以改成单击开始/停止或双击开始/停止。

## 功能

- 使用全局 macOS 快捷键打开。默认是 `Option+Space`。
- 用 modifier key 快捷键开始短语音输入。默认是 Right Option 按住录音，也可以改成单击开始/停止或双击开始/停止。
- 选中文本并短暂停顿后显示选区动作，可快速翻译、自定义 Translate prompt、使用 AI 发音；翻译结果窗口可调整大小并记住上次尺寸，也会为重复翻译提供 7 天本地缓存。
- 超过 1,500 个字符的选中文本会被忽略，避免误选整页时触发。
- 可直接播放选中文本，也可在翻译结果里分别播放原文和译文。
- 内置文本处理模式：
  - To Simple and Correct English
  - To Chinese Summary
  - Voice Cleanup
- 把生成结果插回之前聚焦的应用。
- 插入和强制取词后都会恢复你的剪贴板内容。自动选区动作优先通过 Accessibility 读取，在支持的浏览器里会尝试浏览器选区读取，然后按设置里的强制取词模式 fallback；选中文本后快速按两次 `Command+C`，可以显式用刚复制的剪贴板文本触发选区动作。
- 可以编辑 prompt modes、OpenAI 模型、timeout、temperature、写作快捷键、语音快捷键、语音录音方式、麦克风、speech preset、speech endpoint、speech model、转写后处理方式、选区翻译语言、选区 Translate prompt、AI 发音声音和 AI 发音速度。
- 在本地 History 中查看成功的写作、语音和选区结果，连续重复项会自动合并，原文/结果文本可选择，可一键复制结果或清空全部历史。
- 使用一把共享的 OpenAI API key 处理写作、语音转写、选区翻译和发音。
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
- Accessibility 权限，用于回到上一个应用并粘贴生成结果。
- Microphone 权限，用于语音输入。
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
- `Right Option`：默认按住进行语音输入。可以在 Settings 中修改快捷键、关闭语音快捷键，或改成单击/双击录音方式。
- 模式启动器中的 `↑` / `↓`：在筛选出的 Prompt 模式之间移动高亮。
- 模式启动器中的 `Tab`：确认高亮的 Prompt 模式并聚焦源文本编辑器。
- 模式启动器中的 `Return`：未处于输入法组合状态时，该按键会被拦截，不执行任何启动器操作，并让启动器保持打开；输入法正在组合文字时，仍可用它确认文字或候选项。
- 编辑器中的 `Enter`：处理源文本；插入由当前模式生成的结果；如果可见结果由之前的模式生成，则用刚确认的新模式重新生成。
- `Command+Enter`：不调用模型，直接插入原文。
- `Command+Up` / `Command+Down`：切换可见 prompt modes。
- `Escape`：每按一次只返回一层，依次从结果回到源文本编辑器、模式启动器，再关闭 popover。处理文本期间按下会取消生成并停留在编辑器。
- `Command+,`：Inklet 激活时打开 Settings。

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
- 日常手动测试 app 时使用 `scripts/run-local-app.sh`，不要打开 worktree 里的 `dist/...` bundle，这样本机 Accessibility 和 Keychain 授权会绑定到同一个稳定 app 身份。
- 剪贴板和 Accessibility 流程是核心体验，需要谨慎处理。
- 项目仍处于 MVP 阶段，README 应描述当前代码已经支持的能力，而不是未来计划。

## 隐私

- Inklet 使用你配置的 OpenAI API key 调用 OpenAI，处理写作、语音转写、选区翻译和发音。
- 使用语音输入时，临时音频会发送到 OpenAI 转写接口。
- OpenAI API key 存储在你的 Mac 本地。
- Inklet 使用 Accessibility 权限回到上一个应用并粘贴文本。
- Inklet 只在录音语音输入时使用 Microphone 权限。
- Inklet 会临时使用剪贴板完成插入和已配置的强制取词备用读取，然后恢复之前的剪贴板内容。
- Inklet 会把成功的写作、语音和选区原文/结果作为本地 History 保存，直到你在 Settings 中清空；连续重复项会自动跳过。
- 选区动作会在你选中其他 App 中的文字后，优先通过 Accessibility 读取当前选区；在支持的浏览器中，也会尝试用浏览器 JavaScript 读取 `window.getSelection()`。如果这些方式失败，设置中的强制取词模式可以短暂调用菜单复制和/或 `Command+C`，恢复之前的剪贴板，并使用复制出的文本。你可以在设置中关闭强制取词。选中文本后快速按两次 `Command+C`，会显式读取刚复制的剪贴板文本。Inklet 不会保存仅被选中的文本；只有成功完成的动作会进入本地 History。
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
