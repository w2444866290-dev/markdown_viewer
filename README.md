# Markdown Viewer

A lightweight native macOS Markdown editor built with Swift and AppKit.

## Features

- Live Markdown editing with visual formatting, similar to a compact Obsidian-style editor.
- Open a single Markdown file or an entire directory.
- Directory sidebar with expandable folders and nested text files.
- Markdown rendering for headings, emphasis, links, images, quotes, lists, tasks, code, rules, and aligned tables.
- Plain-text editing for common config/source files such as YAML, JSON, TOML, Swift, shell scripts, and text files.
- Save and Save As support.

## Requirements

- macOS 13 or newer
- Xcode Command Line Tools

## Build

```bash
./scripts/build.sh
```

The app is written to:

```text
dist/MarkdownViewer.app
```

To also create a zip:

```bash
./scripts/build.sh --zip
```

## Run

```bash
open dist/MarkdownViewer.app
```

Launch with the debug HUD enabled (the only recognized flag; no positional arguments):

```bash
dist/MarkdownViewer.app/Contents/MacOS/MarkdownViewer --debug
```

## Testing

Run the whole test suite with one command:

```bash
./scripts/test.sh
```

The tests are written against Apple's **Swift Testing** framework (`import Testing`), not XCTest.
Use `./scripts/test.sh` as the recommended and shared entry point; the full suite runs green through that script.
On the current **Command Line Tools**-only environment, bare `swift test` fails with `no such module 'Testing'` because SwiftPM does not add the CLT `Testing.framework` search path by default.

`scripts/test.sh` makes the suite runnable on both setups without hardcoding any absolute path.
It derives everything from `xcode-select -p` at run time:

- On a **Command Line Tools** machine, `Testing.framework` exists under the CLT developer directory but off the default search paths, so the script adds the compiler (`-F`) and loader (`rpath`) flags that point at it.
- On a **full Xcode** machine, the framework is already on the default search paths, so the script may just run `swift test` internally.

Extra arguments pass straight through, e.g. filter to one suite:

```bash
./scripts/test.sh --filter IncrementalTests
```

The tests are **characterization tests** over the live Markdown styling engine (`LiveMarkdownStyler`): they read back the attributes actually written into an `NSTextStorage` and pin the current behaviour, including a differential-oracle edit matrix (incremental restyle must equal a full restyle) and the "所见即所搜" body-only search invariant.

`LiveMarkdownStyler.bodyPointSize` is a process-wide value, so all styler suites are collected under a single `.serialized` parent suite (`StylerSuites`) and any test that needs a non-default body size must go through the `withBodyPointSize(_:_:)` scoped helper (set + restore), which keeps the global from leaking across tests.

## Project Structure

Source lives under `Sources/MarkdownViewer/`, a single SwiftPM executable target (one module) grouped into shallow feature folders:

```text
Sources/MarkdownViewer/
  App/        # 应用生命周期与启动：入口、--debug 开关、版本标签、窗口配置、崩溃日志
  Shell/      # 顶层三栏布局与外壳组件：主视图、头部（标签/按钮）、状态栏（hover URL / 调试读数）
  Editor/     # TextKit 编辑面：NSViewRepresentable、Coordinator、文本视图子类、AppKit↔SwiftUI 观察桥、代码块复制浮层
  Styling/    # Markdown 实时排版引擎：自定义属性键、卡片绘制、解析与样式规则
  Documents/  # 文档与文件模型：tab/目录状态中枢、模型 struct、会话持久化
  Find/       # 查找替换：共享状态、查找引擎、查找条 UI
  Outline/    # 右侧大纲：标题解析、大纲 rail 视图
  Sidebar/    # 左侧文件侧栏
  Palette/    # 命令面板：⌘K 视图、无边框面板宿主
  UI/         # 共享设计系统与基础组件：设计 token、图标、tooltip、toast
```

## UI Reference

The `ui/` directory contains the original HTML design reference files used during interface iteration.
