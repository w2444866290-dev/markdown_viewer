# Markdown Viewer

> This file captures **product positioning and interaction form** (the business layer). Implementation details do not belong here — they live in the code and in `SPEC-ALIGNMENT.md` (UI-alignment / progress tracking), and the technology may change.

## Product positioning
A native **macOS local Markdown editor** built around **"beautify as you write"** immersive editing: the user types raw Markdown and it is laid out beautifully in place, syntax symbols fade away, it reads clean yet stays editable at any moment — **there is no separate preview pane; what you see is what you edit**. Aimed at people who write and read Markdown locally (notes, docs, technical writing).

## Product principles
- **Quiet, restrained reading experience**: syntax markers hidden or dimmed, body text stays clean.
- **What-you-see-is-what-you-edit**: a single document beautified in place, no split preview/source panes.
- **Keyboard-first**: core actions all have shortcuts; the command palette reaches anything in one step.
- **Native and light**: standard macOS window and interactions.

## Interface and interaction form
**Three regions**: left **file sidebar** · center **editing area** · right **outline navigation**; a **tab bar** on top; plus a **command palette** and a **find/replace** overlay.

- **Editing area (core)**: typing Markdown beautifies instantly — headings, bold/italic, inline code, code blocks, quotes, lists, tables, links, images, and horizontal rules all take shape in place; most syntax symbols are hidden, a few (list markers, link addresses, code language labels) stay dimmed for easy editing. **Non-Markdown files** open as source and are labeled at the top. Body font size is adjustable.
- **File sidebar**: browse here after opening a file/folder; supports **filtering** (arrow keys to select, Enter to open); click to open; files with unsaved changes are marked. Draggable to resize, and collapsible as a whole. The command-palette entry sits at the bottom.
- **Tabs**: multiple documents in parallel, unsaved ones marked, closing requires a second confirmation (to prevent accidental close), and a just-closed tab can be restored.
- **Right outline**: lists the current document's headings, minimal at rest and expanding to text on hover; **highlights the current heading as you scroll**; clicking jumps smoothly with a brief highlight. Shown only for Markdown documents.
- **Find/replace (⌘F)**: type a keyword and **press Return to search**; Return jumps to the next, Shift+Return to the previous; supports case-sensitive / whole-word / regex; replace and replace-all.
- **Command palette (⌘K / double-Shift)**: quickly jump to any open or known document, or run a command (new, save, open, font size, sidebar, restore tab, etc.).
- **Light feedback**: actions show a toast (copied / saved / font-size changed, etc.), buttons have hover hints, and hovering a link shows its address in the bottom-left.

## Key product decisions (and rationale)
- **Blank on first launch**: opens to a single blank new document, **no demo files inserted** — a real product starts clean and is filled by the user opening files/folders.
- **Search on Return** (not search-as-you-type): steadier, no distraction.
- **Folders collapsed by default** (confirmed to keep).
- **Drag-and-drop accepts only `.md / .markdown / .txt`**; other types show a hint.

## Not yet provided (known gaps)
- **Session restore**: after quitting, it does not yet remember the previous tabs, font size, sidebar width, or scroll position (planned alongside the document-model work).
