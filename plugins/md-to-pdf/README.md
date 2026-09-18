# md-to-pdf

Convert GitHub-flavored markdown to a PDF that looks like github.com's rendering — real `github-markdown-css` through headless Chrome, not LaTeX.

## Installation

```bash
claude plugin install md-to-pdf --marketplace ericboehs/agent-plugins
```

Requires `pandoc` and Google Chrome (or Chromium).

## Usage

- `/md-to-pdf` — also triggers on "convert this markdown to pdf", "render X.md as a pdf"

Or call the script directly:

```bash
md2pdf input.md              # writes input.pdf
md2pdf input.md out.pdf      # custom output path
MD2PDF_THEME=dark md2pdf input.md
```

## Why Chrome instead of LaTeX

pandoc's LaTeX path (Eisvogel and friends) produces a typeset document, which is the wrong look for engineering docs and mangles wide tables. Rendering the same `github-markdown-css` that github.com serves, in the same engine a browser uses, gives a PDF that matches what you saw in the preview.

The bundled `assets/github-print.css` adds what a screen stylesheet doesn't cover: `@page` size and margins, wide-table wrapping, `page-break-inside: avoid` on code blocks, and avoid-break rules on headings.
