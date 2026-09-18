# copy-for-slack

Convert the last assistant message from Markdown to Slack-compatible formatting and copy it to the clipboard.

## Installation

```bash
claude plugin install copy-for-slack --marketplace ericboehs/agent-plugins
```

## Usage

- `/copy-for-slack` — Convert the most recent assistant message to Slack formatting and copy it via `pbcopy`

Also triggers on "copy for slack" / "copy that for slack".

## Conversions

- `**bold**` → `*bold*`
- `_italic_` / `*italic*` → `_italic_`
- `#`/`##`/`###` headings → `*bold heading*` on its own line
- `- list items` → `• list items` (nesting preserved)
- `[text](url)` → `<url|text>`
- Horizontal rules (`---`) → `———`
- Inline code, code fences, and blockquotes pass through unchanged
- HTML tags removed

## Requirements

- macOS (`pbcopy`)
