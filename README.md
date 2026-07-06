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
