# pptx

Generate and edit PowerPoint decks with [pptxgenjs](https://gitbrent.github.io/PptxGenJS/), with a QA loop that renders each slide and looks at it.

## Installation

```bash
claude plugin install pptx --marketplace ericboehs/agent-plugins
```

```bash
npm install pptxgenjs
brew install libreoffice poppler   # for the QA render loop
```

## Usage

Ask for a deck and the `pptx-generator` agent picks it up — "make me a slide deck about X", "add a slide to deck.pptx", "fix the layout on slide 3".

## What's in it

- **`agents/pptx-generator.md`** — the agent: design, generate, then verify
- **`references/pptx-reference.md`** — 650 lines of pptxgenjs API notes, design guidelines, and the pitfalls that silently corrupt files

## Why the reference exists

pptxgenjs fails in ways that don't look like failures — the script exits 0 and PowerPoint refuses the file. The reference catalogs the ones worth knowing:

- a `#` prefix on a hex color corrupts the file
- so does 8-character hex (opacity encoded in the color string)
- option objects are mutated in place, so reusing one across calls silently corrupts later slides — use factory functions
- `ROUNDED_RECTANGLE` with an accent border overlay leaves the corners uncovered

## The QA loop

Generating a deck that opens is not the same as generating a deck that looks right. The agent converts the result to images and inspects them:

```bash
soffice --headless --convert-to pdf output.pptx
pdftoppm -r 150 output.pdf slide
```

Then it reads each slide image and fixes what it sees before handing the deck over.
