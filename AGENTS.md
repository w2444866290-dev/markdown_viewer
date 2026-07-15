# Markdown Viewer

> This file captures product positioning and interaction form at the business layer.
> Implementation details live in the code and in `SPEC-ALIGNMENT.md`, and the technology may change.

## Product positioning

Markdown Viewer is a native macOS editor for local Markdown and MDX documents.
Its core experience is "beautify as you write": the document is rendered as a quiet reading surface, and clicking a block turns only that block back into editable source.
There is no split source and preview layout.
A pure preview mode is available when the user wants a distraction-free view of the same document without block-source or table-grid editing.

## Product principles

- The document should feel calm and readable while remaining editable in place.
- Editing should be block-local, so changing one block does not disrupt the rest of the page.
- Markdown source must remain lossless, including whitespace, line endings, and the absence of a final newline.
- Core actions should be keyboard-first and reachable from the command palette.
- The app should use standard macOS windows and interactions and remain lightweight.

## Interface and interaction form

The window contains a resizable file sidebar at the far left, a content outline rail along the left edge of the editing canvas, the document page in the center, a tab bar at the top, and lightweight overlays for commands and find/replace.

- The editing area renders headings, paragraphs, emphasis, inline code, fenced code, quotes, nested lists, tasks, tables, links, images, horizontal rules, and footnotes as native blocks.
- Clicking a rendered block reveals that block's Markdown source in place, while clicking a table cell opens the native grid editor for that table.
- Enter, Backspace, Tab, Shift+Tab, arrow-boundary movement, and common inline formatting shortcuts preserve list, task, quote, and block structure.
- Pure preview mode is toggled with `Command+Shift+P` and removes block-source and table-grid editing affordances without introducing a second pane.
- Code copying, task toggling, links, and footnote navigation remain interactive in pure preview.
- `.md`, `.markdown`, and `.mdx` files use the rendered block experience.
- Supported non-Markdown text and source files open as plain editable source and are labeled as non-Markdown.
- The file sidebar supports recursive browsing, filtering, arrow-key selection, Return to open, active and dirty indicators, resizing, and whole-sidebar collapse.
- Folders are expanded when a folder is first opened, matching the authoritative prototype, and restored expansion state takes precedence on relaunch.
- Tabs support multiple documents, dirty markers, two-step confirmation before closing a dirty tab, and restoration of the most recently closed tab.
- Session restore includes open tabs and unsaved edits, the active tab, font size, sidebar state and width, folder expansion, and each tab's scroll position.
- The content outline appears only for rendered Markdown and MDX documents, stays minimal at rest, expands to heading labels on hover, tracks the current heading, and supports smooth jump navigation with a brief highlight.
- Find/replace with `Command+F` searches visible document text instantly as the query changes.
- Return and Shift+Return move to the next and previous result, and the panel supports case sensitivity, whole-word matching, regular expressions, capture-group replacement, and replace-all.
- The command palette opens with `Command+K` or double Shift and reaches known documents and app commands in one step.
- Toasts, hover hints, link destinations, code-copy feedback, and task-toggle feedback provide lightweight confirmation.

## Key product decisions

- First launch opens one blank untitled Markdown document and does not insert demo content.
- Editing is a native block-based experience, while pure preview is an optional mode of the same single document surface.
- Search is instant as the query changes, while Return is reserved for result navigation.
- Newly opened folders start expanded to match the prototype, while a restored session keeps the user's saved expansion state.
- Drag and drop accepts `.md`, `.markdown`, `.mdx`, and `.txt` files, and unsupported types show a hint.
- The authoritative interface reference is `ui/Markdown Viewer.dc.html`.
