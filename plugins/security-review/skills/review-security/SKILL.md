---
name: review-security
description: Security review of branch changes. An Anthropic-derived reviewer and deterministic scanners (gitleaks, brakeman, zizmor, bundle-audit, npm audit, semgrep) run in parallel as isolated agents, then an independent verifier tries to disprove each candidate so only confirmed vulnerabilities are reported. Use when user says "/review-security", "security review my changes", or wants a vulnerability check before opening a PR.
argument-hint: "[--base REF] [--model M] [--no-scanners] [--min-confidence N]"
disable-model-invocation: true
---

# Security Review

Run the pipeline, then present its report. Reviewer and verifier prompts, the diff, and raw scanner output never enter your context; only the finished report does.

## Run it

```bash
plugins/security-review/skills/review-security/scripts/review-security.sh
```

Use the absolute path to the script in this skill's directory, and pass through any arguments the user gave. It prints progress to stderr and the **report path** (`<outdir>/report.md`) to stdout. It can take several minutes; run it in the foreground with a generous timeout.

| Invocation | Behavior |
|---|---|
| `review-security.sh` | Reviews the auto-detected range |
| `review-security.sh --base main` | Reviews `main...HEAD` |
| `review-security.sh --dry-run` | Shows the range and which scanners apply, then exits |
| `review-security.sh --no-scanners` | LLM reviewer and verifiers only |
| `review-security.sh --model <m>` | Overrides the model for every child agent |
| `review-security.sh --min-confidence 7` | Loosens the verifier threshold (default 8/10) |

### Diff range resolution

1. `--base REF` → `REF...HEAD`
2. else uncommitted changes exist → `git diff HEAD` (untracked files are not included; `git add -N` them first)
3. else → `origin/<default-branch>...HEAD`

### Pipeline

1. **Find candidates, in parallel.** An LLM reviewer (Anthropic's `/security-review` methodology plus Rails guidance when Ruby changed) and every applicable scanner. Scanner hits are kept only on or near lines the diff adds.
2. **Verify.** Each candidate gets its own fresh, read-only agent that tries to disprove it: is it introduced here, is the input attacker-controlled, does a framework or upstream check neutralize it, can a concrete exploit be built?
3. **Report.** Findings confirmed at ≥ 8/10 are listed with source, sink, exploit, and fix. Everything else is listed in one line with the verifier's reason.

## Then present

Read the report. Present the **Findings** section in full, preserving every `file:line`, exploit scenario, and recommendation. Then summarize in a line or two:

- **Unverified** items, which need a human look. Never drop these silently.
- How many candidates were **filtered out**, mentioning any the user may want to double-check.
- **Coverage** gaps worth fixing, such as a skipped scanner that applies to this project (for example `brakeman` not installed in a Rails app).

If the report says the LLM reviewer failed, say so plainly: the review is scanner-only.

Do not fix anything until the user asks. Never repeat secret values; refer to them by `file:line` and type.

## Notes

- Projects can add a threat model or extra checks in `.claude/claude-security-guidance.md` (the same file Anthropic's security-guidance plugin reads). It is ignored when the diff under review modifies it.
- Cost: one reviewer run plus one verifier run per candidate (capped by `--max-candidates`, default 15; `--jobs` verifiers at a time, default 4).
- Artifacts (raw reviewer output, scanner SARIF/JSON, every verdict) stay in the output directory for auditing.
