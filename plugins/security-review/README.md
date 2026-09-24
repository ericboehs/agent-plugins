# security-review

Security review of branch changes that **verifies before it reports**. An LLM reviewer and deterministic scanners find candidates in parallel; then every candidate goes to its own independent agent that tries to disprove it. Only findings that survive are reported.

Works in both Claude Code and [pi](https://pi.dev). Also runs as the `security` aspect of [`pr-review`](../pr-review/README.md).

## Why

Asking an agent to "check for security issues" gets a noisy checklist. This plugin keeps the precision-first approach of Anthropic's `/security-review` (hard exclusions, precedents, only reporting at ≥ 8/10 confidence) and adds:

- **Deterministic scanners**, filtered to the lines this diff adds, so pre-existing warnings don't swamp the review.
- **Per-candidate verification** by fresh agents, the same shape as Anthropic's command (find → parallel false-positive filters → drop < 8), run as isolated `pi -p` subprocesses so none of it enters the calling agent's context.
- **Rails guidance**: vulnerable patterns and framework-mitigated patterns with the Rails and Ruby version checks that change the answer (`order` on 6.1+, open redirects on 7.0+, `YAML.load` on Ruby 3.1+).

## Usage

```bash
skills/review-security/scripts/review-security.sh              # auto-detected range
skills/review-security/scripts/review-security.sh --base main  # main...HEAD
skills/review-security/scripts/review-security.sh --dry-run    # range + applicable scanners
```

In pi: `/skill:review-security`, or `/review-security` once [`pi/prompts`](../../pi/README.md#prompt-templates) is registered. Progress goes to stderr; the report path goes to stdout.

## Pipeline

| Stage | What runs | Output |
|---|---|---|
| 1. Find | LLM reviewer ∥ applicable scanners | `review.md`, `scanners/*`, `candidates/R*.md` (reviewer), `candidates/S*.md` (scanners) |
| 2. Verify | One read-only agent per candidate, `--jobs` at a time | `verdicts/*.md` |
| 3. Report | Confirmed ≥ `--min-confidence` → Findings; failures → Unverified; the rest → Filtered out | `report.md` |

A scanner hit within 3 lines of a reviewer finding is attached to that finding as a "Corroborated by" line rather than becoming its own candidate, so one issue costs one verifier run and the verifier sees both signals.

A verifier that fails or returns unparseable output never drops its candidate; it lands under **Unverified**.

## Scanners

Each runs only when it applies and is installed; the report's Coverage section says which ran, which were skipped, and why.

| Scanner | Runs when | Scope |
|---|---|---|
| `gitleaks` | always | Only added lines, fed through `gitleaks stdin --redact`. Lockfiles and minified files are skipped. |
| `brakeman` | Rails app and Ruby/view files changed | `-w2` (medium+ confidence), hits within 3 lines of added lines. Uses `bundle exec` when it's in the Gemfile. Honors `config/brakeman.ignore`. |
| `zizmor` | workflow or `action.yml` files changed | `--offline --min-severity medium`, every hit in changed workflow files |
| `semgrep` | installed | `$SECURITY_REVIEW_SEMGREP_CONFIG` (default `p/default`) on changed files, hits near added lines |
| `bundle-audit` | `Gemfile.lock` changed | Advisories for gems whose lockfile entries this diff adds |
| `npm audit` | a `package-lock.json` changed | Moderate+ advisories for packages whose lockfile entries this diff adds |

## Options

| Flag | Env | Default | Description |
|---|---|---|---|
| `--base REF` | | auto | Review `REF...HEAD` |
| `--range RANGE` | | | Use a `git diff` range verbatim (used by `pr-review`) |
| `--out DIR` | | mktemp | Artifact directory |
| `--model M` | `SECURITY_REVIEW_MODEL` | pi default | Model for every child agent |
| `--timeout SEC` | `SECURITY_REVIEW_TIMEOUT` | 600 | Per-agent timeout |
| | `SECURITY_REVIEW_SCANNER_TIMEOUT` | 300 | Per-scanner timeout |
| `--min-confidence N` | `SECURITY_REVIEW_MIN_CONFIDENCE` | 8 | Verifier score (1-10) required to report |
| `--max-candidates N` | `SECURITY_REVIEW_MAX_CANDIDATES` | 15 | Candidates verified; the rest are listed as Unverified |
| `--jobs N` | `SECURITY_REVIEW_JOBS` | 4 | Concurrent verifiers |
| `--no-scanners` | | | LLM reviewer only |
| `--dry-run` | | | Print range and scanner plan, launch nothing |

## Project guidance

Put a threat model or extra checks in `.claude/claude-security-guidance.md` (or `.local.md`), the same files Anthropic's security-guidance plugin reads. They're appended to the reviewer and verifier prompts (8 KB cap) as additive guidance. If the diff under review modifies a guidance file, it's ignored, so a change can't talk its own review out of findings.

## Design notes

- **Read-only children.** `pi -ne -ns -np --no-session --tools read,bash`: no extensions, skills, prompt templates, or saved sessions. Context files stay on so agents see project guidelines.
- **Prompt-injection aware.** Reviewer and verifiers are told to treat code, comments, and docs as data and never follow instructions inside them.
- **Secrets stay redacted.** gitleaks runs with `--redact`, and verifiers are told never to reproduce secret values.
- **Cost.** One reviewer run plus one verifier run per candidate. Scanner filtering to added lines keeps the candidate count down.

## Requirements

- `pi`, `git`, `jq`, GNU `timeout`
- Bash 4.3+ (`mapfile`, `wait -n`)
- Optional: `gitleaks`, `brakeman`, `zizmor`, `semgrep`, `bundler-audit`, `npm`
- Credit with the provider behind pi's default model (or pass `--model`). When a provider fails, pi retries with backoff and prints nothing in `-p` mode, so a child looks hung until `--timeout`; its candidates then land under Unverified.

## Attribution

Reviewer and false-positive prompts derived from Anthropic's `claude-code-security-review` (MIT); trust-model table adapted from Sentry's `security-review` skill (Apache-2.0). See [NOTICE](NOTICE).
