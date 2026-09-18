# gist

Create and update GitHub Gists with auto-generated README comments.

## Installation

```bash
claude plugin install gist --marketplace ericboehs/agent-plugins
```

## Usage

- `/gist-create <filepath>` — Create a public gist with a README comment
- `/gist-update <filepath>` — Update an existing gist and its README comment

## Features

- Creates public gists by default (pass "private" for secret gists)
- Auto-generates a comprehensive README as the first gist comment
- Updates existing gists by matching filename
- README includes install instructions, usage examples, and dependencies

## Requirements

- `gh` (GitHub CLI), authenticated
