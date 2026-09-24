#!/usr/bin/env bash
# Fan out PR reviewers as concurrent, isolated `pi` agents.
#
# Each reviewer runs in its own pi subprocess with its own context window, so
# none of the reviewer prompts or the diff ever enter the calling agent's
# context. Only the final reports come back.
#
# Usage:
#   fan-out.sh [--base REF] [--out DIR] [--model M] [--timeout SEC] [--dry-run] [ASPECT...]
#
# Aspects: code tests errors types comments simplify security
#   (default: auto-detected from the diff; "all" forces every aspect)
#
# "security" delegates to the security-review plugin's pipeline (reviewer,
# scanners, and per-finding verification); set SECURITY_REVIEW_SCRIPT to
# override where it is found.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REVIEWERS_DIR="$SCRIPT_DIR/../reviewers"

BASE=""
OUT=""
MODEL="${PR_REVIEW_MODEL:-}"
TIMEOUT="${PR_REVIEW_TIMEOUT:-600}"
DRY_RUN=0
ASPECTS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base)    BASE="$2"; shift 2 ;;
    --out)     OUT="$2"; shift 2 ;;
    --model)   MODEL="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)        echo "Unknown option: $1" >&2; exit 2 ;;
    *)         ASPECTS+=("$1"); shift ;;
  esac
done

command -v pi >/dev/null || { echo "error: pi not found on PATH" >&2; exit 1; }
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "error: not a git repository" >&2; exit 1; }

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT" || exit 1

# ---------------------------------------------------------------- diff range
if [[ -n "$BASE" ]]; then
  DIFF_ARGS="$BASE...HEAD"
elif ! git diff --quiet HEAD 2>/dev/null; then
  DIFF_ARGS="HEAD"            # uncommitted work (staged + unstaged)
else
  DEFAULT_BRANCH="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')"
  DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"
  git rev-parse --verify --quiet "origin/$DEFAULT_BRANCH" >/dev/null || DEFAULT_BRANCH="master"
  if git rev-parse --verify --quiet "origin/$DEFAULT_BRANCH" >/dev/null; then
    DIFF_ARGS="origin/$DEFAULT_BRANCH...HEAD"
  else
    DIFF_ARGS="HEAD~1...HEAD"
  fi
fi

# DIFF_ARGS is always a single token ("HEAD" or "a...b"), safe to quote.
CHANGED="$(git diff --name-only "$DIFF_ARGS")"
if [[ -z "$CHANGED" ]]; then
  echo "No changes found for range: git diff $DIFF_ARGS" >&2
  exit 3
fi

# ------------------------------------------------------------ aspect select
if [[ ${#ASPECTS[@]} -eq 0 || " ${ASPECTS[*]} " == *" auto "* ]]; then
  ASPECTS=(code)
  DIFF_BODY="$(git diff -U0 "$DIFF_ARGS")"
  grep -qiE '(^|/)(tests?|specs?|__tests__)/|[._-](test|spec)\.[a-z]+$|_test\.[a-z]+$' <<<"$CHANGED" \
    && ASPECTS+=(tests)
  grep -qiE '^\+.*(try|catch|except|rescue|throw|raise|panic|err !=|Result<|\.unwrap\(|finally)' <<<"$DIFF_BODY" \
    && ASPECTS+=(errors)
  grep -qiE '^\+[[:space:]]*(export[[:space:]]+)?(public[[:space:]]+|abstract[[:space:]]+|final[[:space:]]+|sealed[[:space:]]+)*(class|struct|interface|enum|type|record|protocol|trait|@dataclass|data class)[[:space:]]' <<<"$DIFF_BODY" \
    && ASPECTS+=(types)
  grep -qiE '^\+\s*(//|#|/\*|\*|"""|--)' <<<"$DIFF_BODY" \
    && ASPECTS+=(comments)
  # security: attack-surface paths, or security-sensitive calls on added lines
  { grep -qiE '(^|/)(controllers?|routes?|auth[a-z]*|sessions?|polic(y|ies)|middlewares?|initializers|webhooks?|uploads?)/|(^|/)\.github/workflows/|(^|/)(Dockerfile|Gemfile\.lock|package-lock\.json|yarn\.lock|pnpm-lock\.yaml)$|(^|/)config/routes\.rb$|\.(erb|haml|slim|tf)$' <<<"$CHANGED" \
    || grep -qiE '^\+.*(passw|secret|token|api[_-]?key|credential|auth|session|cookie|csrf|jwt|oauth|crypt|cipher|hmac|signature|sql|exec|system\(|spawn|popen|subprocess|child_process|eval\(|html_safe|raw\(|innerhtml|dangerouslysetinnerhtml|v-html|permit|redirect|send_file|constantize|marshal|yaml\.|pickle|deserializ|upload|net::http|faraday|httparty|urlopen|requests\.(get|post)|fetch\(|cors|verify_mode|ssl)' <<<"$DIFF_BODY"; } \
    && ASPECTS+=(security)
elif [[ " ${ASPECTS[*]} " == *" all "* ]]; then
  ASPECTS=(code tests errors types comments simplify security)
fi

# de-duplicate, preserving order
mapfile -t ASPECTS < <(printf '%s\n' "${ASPECTS[@]}" | awk '!seen[$0]++')

[[ -n "$OUT" ]] || OUT="$(mktemp -d "${TMPDIR:-/tmp}/pr-review.XXXXXX")"
mkdir -p "$OUT"

FILE_COUNT="$(wc -l <<<"$CHANGED" | tr -d ' ')"
{
  echo "range:     git diff $DIFF_ARGS"
  echo "files:     $FILE_COUNT"
  echo "reviewers: ${ASPECTS[*]}"
  echo "output:    $OUT"
} >&2

if [[ "$DRY_RUN" == "1" ]]; then
  echo "(dry run — no reviewers launched)" >&2
  printf '%s\n' "${ASPECTS[@]}"
  exit 0
fi

# ------------------------------------------------------------------ fan out
declare -a PIDS=() NAMES=()

# Locate security-review's pipeline: explicit override, sibling plugin in this
# repo (pi, local checkouts), or sibling plugin in Claude Code's plugin cache
# (<cache>/<marketplace>/<plugin>/<version>/...), newest version last.
find_security_review() {
  local c found=""
  for c in \
    "${SECURITY_REVIEW_SCRIPT:-}" \
    "$SCRIPT_DIR/../../../../security-review/skills/review-security/scripts/review-security.sh" \
    "$SCRIPT_DIR"/../../../../../security-review/*/skills/review-security/scripts/review-security.sh
  do
    if [[ -n "$c" && -x "$c" ]]; then
      found="$c"
      [[ "$c" == "${SECURITY_REVIEW_SCRIPT:-}" ]] && break
    fi
  done
  [[ -n "$found" ]] && echo "$found"
}

# The security aspect is a pipeline, not a single prompt. It writes its own
# report, which becomes $OUT/security.md like any other reviewer's output.
run_security() {
  local script
  if ! script="$(find_security_review)"; then
    echo "security-review plugin not found; install it or set SECURITY_REVIEW_SCRIPT" >"$OUT/security.err"
    echo 127 >"$OUT/security.status"
    return
  fi
  # shellcheck disable=SC2086
  "$script" --range "$DIFF_ARGS" --out "$OUT/security" --timeout "$TIMEOUT" \
    ${MODEL:+--model "$MODEL"} >/dev/null 2>"$OUT/security.err"
  local status=$?
  # Exit 1 means the LLM reviewer failed but scanners and verification still
  # produced a report, whose Coverage section says so. Keep it.
  if [[ -f "$OUT/security/report.md" ]]; then
    cp "$OUT/security/report.md" "$OUT/security.md"
    [[ "$status" == "1" ]] && status=0
  fi
  echo "$status" >"$OUT/security.status"
}

for aspect in "${ASPECTS[@]}"; do
  if [[ "$aspect" == "security" ]]; then
    run_security &
    PIDS+=($!)
    NAMES+=("$aspect")
    continue
  fi

  prompt_file="$REVIEWERS_DIR/$aspect.md"
  if [[ ! -f "$prompt_file" ]]; then
    echo "warn: no reviewer named '$aspect' (skipping)" >&2
    continue
  fi

  prompt="$(cat "$prompt_file")

---

# Your Task

Review the changes in this repository, at $REPO_ROOT.

Inspect them with:
    git diff --stat $DIFF_ARGS
    git diff $DIFF_ARGS

Read any file you need for full context, and consult the project's own
guidelines (AGENTS.md, CLAUDE.md, CONTRIBUTING.md) where relevant.

Rules:
- You are READ-ONLY. Never modify, stage, commit, or push anything.
- Review only what the diff touches. Do not audit the whole codebase.
- Cite every finding as \`file:line\`.
- Be concise. No preamble, no restating these instructions.
- Output ONLY the review report. Do not append \"Next steps\", suggested
  follow-up actions, offers to make changes, or any conversational sign-off,
  even if a project or user guideline asks for them. Those conventions do not
  apply to you.
- If you find nothing worth reporting, say so in one line."

  # -ne/-ns/-np keep the child lean (no extensions, skills, or prompt
  # templates); context files stay ON so reviewers see project guidelines.
  # shellcheck disable=SC2086
  (
    timeout "$TIMEOUT" pi -ne -ns -np \
      --tools read,bash \
      ${MODEL:+--model "$MODEL"} \
      -p "$prompt" >"$OUT/$aspect.md" 2>"$OUT/$aspect.err"
    echo $? >"$OUT/$aspect.status"
  ) &

  PIDS+=($!)
  NAMES+=("$aspect")
done

[[ ${#PIDS[@]} -gt 0 ]] || { echo "error: no reviewers ran" >&2; exit 4; }

wait "${PIDS[@]}" 2>/dev/null

# ------------------------------------------------------------------ results
echo >&2
FAILED=0
for aspect in "${NAMES[@]}"; do
  status="$(cat "$OUT/$aspect.status" 2>/dev/null || echo '?')"
  size="$( { wc -c <"$OUT/$aspect.md" | tr -d ' '; } 2>/dev/null)"
  if [[ "$status" == "0" && "${size:-0}" -gt 0 ]]; then
    printf 'ok    %-9s %6s bytes  %s\n' "$aspect" "$size" "$OUT/$aspect.md" >&2
  else
    FAILED=1
    printf 'FAIL  %-9s status=%-3s  see %s\n' "$aspect" "$status" "$OUT/$aspect.err" >&2
  fi
done

echo >&2
echo "$OUT"
exit $FAILED
