# GPT 翻译助手

一个原生 macOS SwiftUI 翻译软件：常驻菜单栏，使用 ChatGPT OAuth 登录的本机 Codex CLI 会话进行翻译，并支持跨应用划词、截图和 OCR。

## 产品构想

做一个简洁的翻译软件与截图软件的融合版：不堆叠复杂界面，把划词翻译、快捷输入、截图标注、OCR 识别和截图翻译串联在同一条轻量工作流中。需要翻译时随手划词，需要记录或说明时直接截图标注，尽量减少应用切换和重复操作。

## 功能

- 菜单栏翻译图标
- 自动识别原文语言，支持中文、英语、日语、韩语、西班牙语、法语和德语
- 在任意应用选中文字后按 `⌘⇧T` 翻译
- 划词翻译默认在选中文字后直接翻译；也可切换为显示翻译图标，将鼠标移到图标上即可翻译
- 按 `⌘⇧S` 截图，拖动选择区域后用 macOS Vision OCR，再翻译识别结果
- 按 `⌘⇧A` 普通截图，使用微信式紧凑工具栏进行画笔、形状、箭头、文字、自由涂抹马赛克、置顶、复制和保存
- 按 `⌘⇧O` 截图 OCR，只识别选区文字并复制到剪贴板，不进行翻译
- 截图选区支持像素放大取色、HEX 与 RGB 色号和 `⌘C` 复制；截图下方可直接显示 OCR 翻译结果
- 截图标注支持手型工具移动画笔、形状、箭头和文字；文字可调整颜色与字号，选中标注后可按 `Delete` 或 `Backspace` 删除
- 画笔、矩形和圆形边框支持滑块无级调节粗细；颜色面板可在常用色卡与连续渐变色盘之间切换
- 可保留多张截图继续取景，置顶截图聚焦后可按 `Esc` 关闭
- 按 `⌘⇧D` 打开类似 Spotlight 的快捷翻译框，自动判断中英文并互译
- 快捷翻译框支持拖动、钉住、复制、写回原输入框，以及最近 20 条本机历史记录
- 划词、普通截图、截图 OCR、截图翻译和快捷翻译框均可在设置中自定义组合键与字母键，重复快捷键会提示冲突
- 主窗口停止输入后自动翻译：机器翻译约 0.28 秒触发，GPT 类翻译约 0.48 秒触发
- OAuth 翻译源在后台预热并复用常驻 CLI 进程，连续翻译不会重复启动 Codex 或 `agy`；Gemini 启用后会在启动时主动唤醒，首次失败时自动在后台唤醒 Antigravity 并重试
- 最近 100 条结果使用内存缓存，重复翻译可立即显示
- 保留段落、Markdown、标点和换行
- 使用 ChatGPT OAuth：应用不要求、不保存 OpenAI API Key
- 支持 OpenAI/ChatGPT OAuth、Gemini/Google OAuth（通过官方 Antigravity CLI）、DeepSeek、智谱 GLM，以及可重复添加的 OpenAI Chat Completions 兼容 API
- 支持 Apple 离线翻译；首次使用缺失语言时由 macOS 下载语言包，之后可离线使用且不消耗 API token（需要 macOS 15 或更高版本）
- 每个自定义 API 可独立设置显示名称、接口地址、模型和 API Key
- 划词和截图悬浮窗支持多来源并行对照、拖拽排序和顺序记忆
- 菜单栏显示所有已开启来源的连接状态，启动时检测，之后每小时检测，也可手动刷新
- 启动时自动检查 GitHub 正式版本，菜单栏右下角提示并可打开新版下载页
- 每个第三方服务和自定义配置的 API Key 独立保存在 macOS 钥匙串
- 可选择预设或自定义模型，并设置关闭、低、中、高、极高推理强度
- 可在菜单栏决定是否翻译中文内容，并可选择是否在 Dock 中显示应用
- 设置中支持隐藏 Dock 图标，并可选择登录 macOS 时自动启动

## 运行

需要 macOS 13 或更高版本和 Swift 6 / Xcode Command Line Tools。若使用 OpenAI/ChatGPT OAuth 翻译源，需要自行安装 Codex CLI 并完成 `codex login`；若使用 Gemini/Google OAuth 翻译源，需要自行安装 Antigravity CLI（`agy`）并完成 Google 登录。

```bash
swift run
```

第一次使用 OpenAI/ChatGPT OAuth 时，需先自行配置 Codex CLI，也可以打开应用“设置”点击“使用 ChatGPT 登录”，在浏览器完成 OAuth。Gemini/Google OAuth 源复用用户自行配置的 `agy` CLI 登录会话。本应用不附带这些 CLI，也不会读取、复制或打包 OAuth Token。DeepSeek、智谱或自定义兼容 API 需要填写对应 API Key。生成并安装应用：

```bash
chmod +x scripts/build-app.sh
./scripts/build-app.sh
open "$HOME/Applications/GPT翻译助手.app"
```

构建脚本会把唯一的应用副本安装到 `~/Applications/GPT翻译助手.app`。首次划词翻译需要在“系统设置 → 隐私与安全性 → 辅助功能”中允许这一份应用；首次截图时需要允许屏幕录制。

应用图标采用自制蓝紫渐变双气泡设计；许可说明见 `THIRD_PARTY_NOTICES.md`。菜单栏图标为适配浅色和深色菜单栏的单色环形翻译标识。

## DMG 安装

从 GitHub Releases 下载 `GPT-Translator-1.2.0-macOS.dmg`，打开后把“GPT 翻译助手”拖入 Applications。当前公开构建未使用 Apple Developer ID 公证；macOS 首次打开时可能需要在 Finder 中右键应用并选择“打开”。

## 隐私与凭据

- 发布包不包含开发者或使用者的 API Key、ChatGPT/OpenAI 登录令牌、账号信息或本机偏好设置。
- OpenAI 登录由用户本机安装的 Codex CLI 管理，应用不会把 OAuth 凭据复制进应用目录。
- DeepSeek、智谱和自定义 API Key 仅写入当前用户的 macOS 钥匙串，不写入源码、配置文件或 DMG。
- 每位安装者需要在自己的 Mac 上完成登录并填写自己的 API Key。

## 请作者喝杯咖啡

如果这个小工具对你有帮助，可以自愿扫码支持后续维护。感谢使用。

<img src="Assets/donate-wechat.jpg" alt="微信赞赏二维码" width="320">

## 认证边界

本项目通过安装者本机的 `codex login` 会话使用 OpenAI/ChatGPT OAuth，不把 ChatGPT token 伪装成普通 API Key。DeepSeek、智谱和自定义来源使用 OpenAI Chat Completions 兼容接口。
