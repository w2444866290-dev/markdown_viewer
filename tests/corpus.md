# H1 Corpus Title — Markdown Rendering Regression Fixture

This document exercises every markdown construct the viewer styles, plus the
known edge cases (empty code lines, over-wide code/table cells, CJK + Latin
mixes). It feeds `--golden-test` so any rendering regression produces a pixel
diff against a committed baseline.

## H2 Section With English Body (uppercase-transform case)

A short paragraph. The next line stays in the same paragraph until a blank line.

This is a deliberately long paragraph meant to wrap across more than one visual
line inside the narrow paper column, so that line-wrapping, justification and
inter-line spacing are all captured in the golden snapshot and any change to the
body font, container width, or line height shows up as a pixel difference here.

### H3 第三级标题（中文）

Inline styles in one line: **bold text**, *italic text*, ***bold italic***,
~~strikethrough~~, and inline `code span` with backticks.

#### H4 Heading
##### H5 Heading
###### H6 Heading

H1 through H6 above appear consecutively to catch heading-spacing regressions.

Heading immediately after a paragraph follows — this paragraph ends here.
## H2 Right After A Paragraph (no blank-line buffer above is intentional)

## H2 链接与自动链接 (Links)

A link with visible text and a hidden URL: [证据链接 evidence link](https://example.com/corpus).
An autolink: <https://example.com/autolink>.

## H2 Fenced Code Blocks

A short fenced block (no language label):

```
plain code, no language
```

A fenced block with a LANGUAGE label:

```swift
func greet(_ name: String) -> String {
    return "Hello, \(name)"
}
```

A fenced block with EMPTY interior lines (the card-contiguity edge case — the
card must stay one continuous rounded run, no hairline split at the blank line):

```text
project/
├── src

│   middle line after a truly empty line

└── README.md
```

A fenced block with VERY LONG lines, wider than the paper column, to test
horizontal overflow / clipping inside the code card:

```bash
echo "this is an intentionally very long single line of code that is far wider than the centered paper column so the code card must clip or scroll rather than reflow the text"
npx -y some-extremely-long-package-name@latest --flag-one --flag-two --flag-three --output /very/long/path/to/the/output/directory/file.txt
```

An ASCII tree using box-drawing characters:

```text
root
┌─────────────┐
│  box header │
├─────────────┤
│  cell A     │
│  cell B     │
└─────────────┘
└── leaf
```

## H2 Lists

Unordered list:

- First unordered item
- Second unordered item
- Third unordered item

Ordered list:

1. First ordered item
2. Second ordered item
3. Third ordered item

Nested list (two levels):

- Top level one
  - Nested one-a
  - Nested one-b
- Top level two
  - Nested two-a

Task list:

- [x] Completed task
- [ ] Pending task
- [x] 完成的任务（中文）
- [ ] 未完成的任务

## H2 Blockquotes

> A single-line blockquote.

> A multi-line blockquote.
> The second quoted line continues the same quote.
> 第三行使用中文继续同一段引用。

---

## H2 Horizontal Rules

Text above a horizontal rule.

---

Text between two horizontal rules.

---

Text below a horizontal rule.

## H2 Tables

A table with short cells:

| Key | Val |
| --- | --- |
| a   | 1   |
| b   | 2   |

A table with LONG cells (wider than the column, forcing truncation/wrap):

| Field | Description |
| --- | --- |
| alarm_id | A very long description cell that is intentionally wider than the available column so the borderless table layout has to handle overflow gracefully without breaking column alignment |
| time_range | Default the most recent one hour window, but this can be overridden by the user with an explicit absolute or relative range expression |

A table mixing CJK and Latin cells:

| 字段 Field | 说明 Description | 必填 Required |
| --- | --- | --- |
| alarm_id | 告警规则或事件的唯一标识 unique id | 是 yes |
| platform | Argos、TCE 等来源平台 source platform | 否 no |

## H2 混合中英文正文 (Mixed CJK / Latin body)

这一段混合了中文与 English words，用来验证 CJK 与 Latin 字形在同一行内的基线对齐、
字间距与换行行为 are all rendered consistently，并且不会因为字体回退而产生跳动。

The end of the corpus.
