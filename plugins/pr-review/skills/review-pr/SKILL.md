---
name: review-pr
description: Comprehensive PR review that fans out specialized reviewers (code, tests, errors, types, comments, simplify, security) as concurrent isolated agents, then aggregates findings into a prioritized report. Use when user says "/review-pr", "review this PR", "review my changes", or wants a pre-PR quality check.
argument-hint: "[aspects...] [--base REF]"
disable-model-invocation: true
---

# PR Review

Fan out specialized reviewers as **concurrent isolated `pi` subprocesses**, then aggregate their reports. Reviewer prompts and the diff never enter your context — only the finished reports do.

## Run it

```bash
plugins/pr-review/skills/review-pr/scripts/fan-out.sh
```

Use the absolute path to the script in this skill's directory. It prints progress to stderr and the **output directory path** to stdout.

| Invocation | Behavior |
|---|---|
| `fan-out.sh` | Auto-detects applicable aspects from the diff |
| `fan-out.sh all` | Runs all seven reviewers |
| `fan-out.sh tests errors` | Runs only those reviewers |
| `fan-out.sh --base main` | Reviews `main...HEAD` |
| `fan-out.sh --model <m>` | Overrides the model for children |

**Aspects:** `code` (always), `tests`, `errors`, `types`, `comments`, `simplify`, `security`.

`simplify` is a polish pass — it only runs when explicitly requested or via `all`.

`security` runs the [security-review](../../../security-review/README.md) plugin's pipeline: an LLM reviewer plus scanners, then an independent verifier per candidate. It auto-runs when the diff touches attack surface (controllers, routes, auth, workflows, lockfiles, templates) or adds security-sensitive calls. Its report is already verified; findings in it are confirmed at ≥ 8/10.

### Diff range resolution

1. `--base REF` → `REF...HEAD`
2. else uncommitted changes exist → `git diff HEAD`
3. else → `origin/<default-branch>...HEAD`

## Then aggregate

Read each `<outdir>/<aspect>.md`, then produce a single report. Do **not** dump the raw reports back to the user.

Merge duplicate findings reported by multiple reviewers into one entry, attributing each to its source. Preserve every `file:line` citation.

```markdown
# PR Review Summary

_Reviewed N files across <range> with: <aspects>_

## Critical Issues (N)
- **[aspect]** Description — `file:line`

## Important Issues (N)
- **[aspect]** Description — `file:line`

## Suggestions (N)
- **[aspect]** Description — `file:line`

## Strengths
- What's genuinely well done

## Recommended Action
1. Fix critical issues first
2. Address important issues
3. Consider suggestions
4. Re-run affected reviewers to verify
```

Severity mapping: `code` confidence 90-100, `errors` CRITICAL, and `security` HIGH findings → Critical. `code` 80-89, `errors` HIGH, `tests` 8-10, and `security` MEDIUM findings → Important. Everything else → Suggestions.

From the `security` report, take only its **Findings** as issues. List its **Unverified** items under Important with a note that they need a human look; never drop them. Mention its filtered-out count and any Coverage gaps (such as a skipped scanner, or a failed LLM reviewer, which makes it a scanner-only review) in one line. Never repeat secret values.

If a reviewer reports nothing, note it in one line rather than omitting it.

## Notes

- Reviewers are **read-only** (`--tools read,bash`) and instructed never to modify files. Any fixes are yours to apply after the user approves.
- Children run with `-ne -ns -np` (no extensions/skills/prompt templates) to stay cheap, but **do** load `AGENTS.md`/`CLAUDE.md` so they can check project guidelines.
- Each reviewer is a real model call. `all` on a large diff costs seven full agent runs, and `security` adds one verifier run per candidate — prefer auto-detection.
- A `FAIL` line means that reviewer errored; its `.err` file has details. Report partial results rather than silently dropping an aspect.
- Best run **before** opening the PR.
