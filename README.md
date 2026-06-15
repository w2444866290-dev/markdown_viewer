# Markdown Viewer

A lightweight native macOS Markdown editor built with Swift and AppKit.

## Features

- Live Markdown editing with visual formatting, similar to a compact Obsidian-style editor.
- Open a single Markdown file or an entire directory.
- Directory sidebar with expandable folders and nested text files.
- Markdown rendering for headings, emphasis, links, images, quotes, lists, tasks, code, rules, and aligned tables.
- Plain-text editing for common config/source files such as YAML, JSON, TOML, Swift, shell scripts, and text files.
- Save and Save As support.
- Built-in self-test mode for layout, Markdown styling, table alignment, directory tree behavior, plain-text editing, and save persistence.

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

Open a specific file or directory:

```bash
dist/MarkdownViewer.app/Contents/MacOS/MarkdownViewer /path/to/notes
```

## Self-Test

The app has a hidden self-test mode:

```bash
dist/MarkdownViewer.app/Contents/MacOS/MarkdownViewer --self-test build/selftest
```

The self-test generates screenshots and validates:

- directory tree rendering, including nested folders and YAML files
- opening Markdown and plain-text files
- editing and saving plain-text files
- visual Markdown styling
- aligned multi-row Markdown tables using AppKit layout coordinates
- three distinct Markdown samples covering the main supported syntax

## UI Reference

The `ui/` directory contains the original HTML design reference files used during interface iteration.
