# pr-review

Comprehensive PR review that fans out specialized reviewers as **concurrent, isolated agents**, then aggregates their findings into one prioritized report.

Works in both Claude Code and [pi](https://pi.dev).

## Why

A port of Anthropic's `pr-review-toolkit` that doesn't depend on a subagent framework. Instead of a Task/subagent tool, it shells out to concurrent `pi -p` subprocesses — so it costs **zero tokens** of the calling agent's context window until it actually runs.

The reviewer prompts (~13KB total) live in separate files that only the *children* ever read. The orchestrator only ever sees the finished reports.

## Usage

Run `/review-pr` (in pi: `/skill:review-pr`, or `/review-pr` once [`pi/prompts`](../../pi/README.md#prompt-templates) is registered), or run the script directly:

```bash
skills/review-pr/scripts/fan-out.sh              # auto-detect aspects
skills/review-pr/scripts/fan-out.sh all          # all seven reviewers
skills/review-pr/scripts/fan-out.sh tests errors # explicit subset
skills/review-pr/scripts/fan-out.sh --base main  # review main...HEAD
skills/review-pr/scripts/fan-out.sh --dry-run    # show what would run
```

Progress goes to stderr; the output directory path goes to stdout. Each reviewer writes `<outdir>/<aspect>.md`.

## Reviewers

| Aspect | Focus | Auto-runs when |
|---|---|---|
| `code` | Project-guideline compliance, bugs, quality (confidence >= 80) | always |
| `tests` | Behavioral coverage gaps, brittle tests | test files changed |
| `errors` | Silent failures, broad catches, unjustified fallbacks | error-handling keywords in diff |
| `types` | Invariant encapsulation, expression, usefulness, enforcement | type/class/struct declarations added |
| `comments` | Comment accuracy vs. code, comment rot | comments added |
| `simplify` | Behavior-preserving clarity improvements | explicit request or `all` |
| `security` | Verified vulnerabilities via the [security-review](../security-review/README.md) pipeline (reviewer + scanners + per-finding verifier) | attack-surface paths or security-sensitive calls in diff |

## Options

| Flag | Default | Description |
|---|---|---|
| `--base REF` | auto | Review `REF...HEAD` |
| `--out DIR` | mktemp | Where reports are written |
| `--model M` | pi default | Model for child agents (`PR_REVIEW_MODEL`) |
| `--timeout SEC` | 600 | Per-reviewer timeout (`PR_REVIEW_TIMEOUT`) |
| `--dry-run` | off | Print selected aspects without running |

## Design notes

- **Read-only.** Children run with `--tools read,bash` and are told never to modify files. Fixes are the orchestrator's job, after you approve them.
- **Lean children.** `-ne -ns -np` disables extensions, skills, and prompt templates in child processes — measured at ~2.2K prompt tokens instead of ~11.8K. Context files (`AGENTS.md`/`CLAUDE.md`) stay enabled so reviewers can check project guidelines.
- **Diff range resolution:** `--base` → uncommitted changes (`git diff HEAD`) → `origin/<default>...HEAD`.
- **Cost.** Each aspect is a full agent run, and `security` adds a verifier run per candidate. Seven reviewers on a large diff is expensive; prefer auto-detection.
- **Security delegates.** The `security` aspect runs the sibling `security-review` plugin's script, found next to this plugin (repo checkout or Claude Code plugin cache) or at `$SECURITY_REVIEW_SCRIPT`. Without it, `security` reports `FAIL` rather than silently disappearing.

## Requirements

- `pi` on `PATH`
- `git`
- Bash 4+ (`mapfile`)

## Attribution

Reviewer prompts derived from Anthropic's `pr-review-toolkit` (Apache-2.0). See [NOTICE](NOTICE).
