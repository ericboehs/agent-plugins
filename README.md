# Eric's Agent Plugins

A collection of agent plugins for Claude Code and pi, for developer productivity.

## Installation

Add this marketplace to Claude Code:

```bash
claude plugin marketplace add ericboehs/agent-plugins
```

Then install individual plugins:

```bash
claude plugin install session-improver
```

## Plugins

### session-improver

Analyze Claude Code session transcripts and recommend improvements to reduce token waste, prevent linter loops, and automate repetitive workflows. See [full documentation](plugins/session-improver/README.md).

**Usage:**
- `/improve-session` — Analyze the most recent session
- `/improve-session <session-id>` — Analyze a specific past session

**What it detects:**
- Linter loops (reek, rubocop, eslint smells triggering repeated edit cycles)
- Tool failures (commands retried 3+ times)
- Repeated workflow patterns
- Excessive file reads (token waste)
- Hook failures
- Permission friction

**What it recommends:**
- CLAUDE.md rules with BAD/GOOD code examples
- PostToolUse hooks for auto-formatting
- Permission rules for auto-approving safe commands
- Hookify rules for behavioral guards
- Skill stubs for reusable workflows

Includes pre-built fix templates for common Ruby linting issues (Reek + RuboCop).

### apple-reminders

Manage Apple Reminders from Claude Code using `remindctl` CLI. See [full documentation](plugins/apple-reminders/README.md).

**Usage:**
- `/reminders` — Show today's reminders
- `/reminders list` — Show all reminder lists
- `/reminders add Buy milk` — Quick add to default list
- `/reminders add Buy milk --list Groceries --due tomorrow` — Add with options

### cli-email

CLI email management using himalaya, mbsync, and neomutt with local Maildir sync and search. See [full documentation](plugins/cli-email/README.md).

**Skills:**
- `/check-email` — List unread, read messages, archive, search email
- `/setup-email` — Guided install/configure of the full CLI email stack

**Stack:** mbsync (IMAP sync) + himalaya (CLI) + neomutt (TUI) + goimapnotify (IMAP IDLE) + qmd (search)

### apple-calendar

Manage Apple Calendar from Claude Code using `ical` CLI with full CRUD, search, and calendar filtering. See [full documentation](plugins/apple-calendar/README.md).

**Skills:**
- `/calendar` — View agenda, create/update/delete events, search calendar
- `/setup-calendar` — Install and configure the ical CLI tool

**Features:** Full CRUD, natural language dates, recurring events, calendar filtering, JSON output with stable event IDs

### slack

Slack messaging, status, and search using `slk` CLI (Slack Gem). See [full documentation](plugins/slack/README.md).

**Skills:**
- `/slack` — Check unread, read messages, search, set status/DND, browse activity
- `/setup-slack` — Install and configure slk CLI

**Examples:**
- `/slack` — Show unread messages across all workspaces
- `/slack messages #eert-teammates-internal --since 1d` — Read recent channel messages
- `/slack search "deploy" --in #platform-sre-team` — Search messages
- `/slack preset focus` — Apply a status preset

### code-lint

Multi-language linting via PostToolUse hooks. Automatically runs configured linters when files are edited, feeding errors back to Claude for immediate correction. See [full documentation](plugins/code-lint/README.md).

**Skills:**
- `/setup-lint` — Detect languages and linters, configure per-project linting
- `/lint` — Run all configured linters across the full project

**Supported:** Ruby (rubocop, reek, brakeman), JS/TS (eslint, biome), Python (ruff, mypy, flake8), Go (golangci-lint), Rust (clippy), Markdown (markdownlint), HTML (htmlhint, prettier), Shell (shellcheck), Any (semgrep — language-agnostic SAST)

### dev-lifecycle

Full feature development lifecycle — plan, implement, test, review, PR, Copilot review, verify CI, QA demo, merge, and clean up in one command. See [full documentation](plugins/dev-lifecycle/README.md).

**Usage:**
- `/dev-lifecycle <feature description>` — Run the full plan-to-merge workflow
- `/dev-lifecycle add rate limiting --skip-copilot` — Skip specific phases
- `/dev-lifecycle fix bug --skip-merge` — Stop before merge for manual review

**QA demo:** Auto-detects CLI (tmux split), web (headed browser), or library (verbose tests). User must approve before merge.

**Companion plugins:** pr-review-toolkit, gh-copilot-review, watch-ci, code-lint (all optional — includes fallbacks)

### gh-copilot-review

Wait for GitHub Copilot PR reviews, address feedback, resolve threads, and push fixes. See [full documentation](plugins/gh-copilot-review/README.md).

**Usage:**
- `/gh-copilot-review` — Wait for Copilot review, apply fixes, resolve threads, commit and push

**Requires:** `gh` (GitHub CLI), `jq`

### watch-ci

Monitor GitHub Actions CI status for the current branch, auto-exiting when checks pass or fail. See [full documentation](plugins/watch-ci/README.md).

**Usage:**
- `/watch-ci` — Watch CI checks, exit on pass/fail

**Requires:** `gh` (GitHub CLI), `jq`

### icloud-downloads

Copy files to iCloud Downloads for easy access on iPhone/iPad. See [full documentation](plugins/icloud-downloads/README.md).

**Usage:**
- `/copy-to-icloud-downloads` — Copy a file to iCloud Downloads for reading on your phone

### gist

Create and update GitHub Gists with auto-generated README comments. See [full documentation](plugins/gist/README.md).

**Usage:**
- `/gist-create <filepath>` — Create a public gist with a README comment
- `/gist-update <filepath>` — Update an existing gist and its README comment

### git-utils

Git workflow utilities — merge PRs, clean up branches, and handle worktrees in one command. See [full documentation](plugins/git-utils/README.md).

**Usage:**
- `/merge-and-cleanup` — Squash merge the current branch's PR, delete the branch, switch to the default branch, pull, and clean up worktree if applicable
- `/commit-and-push` — Stage all changes, commit with a semantic message, and push to origin

## Contributing

Each plugin lives in `plugins/<plugin-name>/` and needs:
- `.claude-plugin/plugin.json` — Plugin manifest
- `skills/` and/or `commands/` — The actual skill/command definitions
- `README.md` — Documentation

## License

MIT
