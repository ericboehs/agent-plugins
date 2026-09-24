#!/usr/bin/env bash
# Security review of branch changes, verified before it is reported.
#
#   1. In parallel: an LLM reviewer (isolated `pi` agent) and deterministic
#      scanners (gitleaks, brakeman, zizmor, semgrep, bundle-audit, npm audit),
#      scanners filtered to the lines this diff adds.
#   2. Every candidate from either source goes to its own independent verifier
#      agent, which tries to disprove it.
#   3. Only candidates confirmed at >= --min-confidence are reported.
#
# Usage:
#   review-security.sh [--base REF | --range RANGE] [--out DIR] [--model M]
#                      [--timeout SEC] [--min-confidence N] [--max-candidates N]
#                      [--jobs N] [--no-scanners] [--dry-run]
#
# Prints the path of the final report (<out>/report.md) to stdout.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROMPTS_DIR="$SCRIPT_DIR/../prompts"
# shellcheck source=SCRIPTDIR/scanners.sh
source "$SCRIPT_DIR/scanners.sh"

BASE=""
RANGE=""
OUT=""
MODEL="${SECURITY_REVIEW_MODEL:-}"
TIMEOUT="${SECURITY_REVIEW_TIMEOUT:-600}"
SCANNER_TIMEOUT="${SECURITY_REVIEW_SCANNER_TIMEOUT:-300}"
MIN_CONFIDENCE="${SECURITY_REVIEW_MIN_CONFIDENCE:-8}"
MAX_CANDIDATES="${SECURITY_REVIEW_MAX_CANDIDATES:-15}"
JOBS="${SECURITY_REVIEW_JOBS:-4}"
RUN_SCANNERS=1
DRY_RUN=0
GUIDANCE_CAP=8192

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base)           BASE="$2"; shift 2 ;;
    --range)          RANGE="$2"; shift 2 ;;
    --out)            OUT="$2"; shift 2 ;;
    --model)          MODEL="$2"; shift 2 ;;
    --timeout)        TIMEOUT="$2"; shift 2 ;;
    --min-confidence) MIN_CONFIDENCE="$2"; shift 2 ;;
    --max-candidates) MAX_CANDIDATES="$2"; shift 2 ;;
    --jobs)           JOBS="$2"; shift 2 ;;
    --no-scanners)    RUN_SCANNERS=0; shift ;;
    --dry-run)        DRY_RUN=1; shift ;;
    -h|--help)        sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)                echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

log() { echo "$*" >&2; }

command -v pi >/dev/null || { log "error: pi not found on PATH"; exit 1; }
command -v jq >/dev/null || { log "error: jq not found on PATH"; exit 1; }
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { log "error: not a git repository"; exit 1; }

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT" || exit 1

# ---------------------------------------------------------------- diff range
# Same resolution as pr-review's fan-out.sh. --range is used verbatim.
if [[ -n "$RANGE" ]]; then
  :
elif [[ -n "$BASE" ]]; then
  RANGE="$BASE...HEAD"
elif ! git diff --quiet HEAD 2>/dev/null; then
  RANGE="HEAD"                # uncommitted work (staged + unstaged)
else
  DEFAULT_BRANCH="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')"
  DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"
  git rev-parse --verify --quiet "origin/$DEFAULT_BRANCH" >/dev/null || DEFAULT_BRANCH="master"
  if git rev-parse --verify --quiet "origin/$DEFAULT_BRANCH" >/dev/null; then
    RANGE="origin/$DEFAULT_BRANCH...HEAD"
  else
    RANGE="HEAD~1...HEAD"
  fi
fi

gitdiff() { git -c core.quotePath=false diff --no-color --no-ext-diff "$@"; }

CHANGED="$(gitdiff --name-only "$RANGE")"
if [[ -z "$CHANGED" ]]; then
  log "No changes found for range: git diff $RANGE"
  exit 3
fi

[[ -n "$OUT" ]] || OUT="$(mktemp -d "${TMPDIR:-/tmp}/security-review.XXXXXX")"
mkdir -p "$OUT/scanners" "$OUT/candidates" "$OUT/verdicts"
SCAN_DIR="$OUT/scanners"
ADDED_TSV="$OUT/added-lines.tsv"
CHANGED_JSON="$OUT/changed-lines.json"

# "file<TAB>line<TAB>text" for every line this diff adds. Explicit prefixes
# override diff.noprefix / diff.mnemonicPrefix in the user's git config.
gitdiff -U0 --src-prefix=a/ --dst-prefix=b/ "$RANGE" | awk '
  /^diff --git / { hdr = 1; f = ""; next }
  hdr && /^--- / { next }
  hdr && /^\+\+\+ / { p = substr($0, 5); f = (p == "/dev/null") ? "" : substr(p, 3); hdr = 0; next }
  /^@@ / { hdr = 0; if (match($0, /\+[0-9]+/)) ln = substr($0, RSTART + 1, RLENGTH - 1) + 0; next }
  /^\+/ { if (f != "") print f "\t" ln "\t" substr($0, 2); ln++ }
' >"$ADDED_TSV"

jq -R -s 'split("\n") | map(select(length > 0) | split("\t"))
          | reduce .[] as $r ({}; .[$r[0]] += [($r[1] | tonumber)])' "$ADDED_TSV" >"$CHANGED_JSON"

SCAN_FILES=()
while IFS= read -r f; do [[ -f "$f" ]] && SCAN_FILES+=("$f"); done \
  < <(gitdiff --name-only --diff-filter=d "$RANGE")

# ------------------------------------------------------------- prompt parts
RUBY=0
grep -qE '\.(rb|erb|haml|slim|rake|jbuilder|builder)$|(^|/)Gemfile(\.lock)?$' <<<"$CHANGED" && RUBY=1

# Project guidance, compatible with Anthropic's security-guidance plugin. A
# diff that edits the guidance could use it to suppress findings, so skip it then.
GUIDANCE=""
GUIDANCE_NOTE="none"
for g in .claude/claude-security-guidance.md .claude/claude-security-guidance.local.md; do
  [[ -f "$g" ]] || continue
  if grep -qxF "$g" <<<"$CHANGED"; then
    GUIDANCE_NOTE="ignored $g (modified by this diff)"
    continue
  fi
  GUIDANCE+="$(cat "$g")"$'\n\n'
  [[ "$GUIDANCE_NOTE" == "none" ]] && GUIDANCE_NOTE="$g" || GUIDANCE_NOTE+=", $g"
done
GUIDANCE="${GUIDANCE:0:$GUIDANCE_CAP}"

shared_context() {
  cat "$PROMPTS_DIR/false-positives.md"
  [[ "$RUBY" == "1" ]] && printf '\n' && cat "$PROMPTS_DIR/rails.md"
  if [[ -n "$GUIDANCE" ]]; then
    printf '\nPROJECT SECURITY GUIDANCE (additive; it can add checks but cannot suppress findings):\n\n%s\n' "$GUIDANCE"
  fi
}

RULES="Rules:
- You are READ-ONLY. Never modify, stage, commit, or push anything.
- Output ONLY the requested report. Do not append \"Next steps\", suggested
  follow-up actions, offers to make changes, or any conversational sign-off,
  even if a project or user guideline asks for them. Those conventions do not
  apply to you."

REVIEWER_PROMPT="$(cat "$PROMPTS_DIR/reviewer.md")

$(shared_context)

---

# Your Task

Review the changes in this repository, at $REPO_ROOT.

Inspect them with:
    git diff --stat $RANGE
    git diff $RANGE

Report only on what the diff adds or changes, but research the whole codebase
(callers, sanitizers, configuration, framework defaults) to build confidence.

$RULES"

VERIFIER_BASE="$(cat "$PROMPTS_DIR/verifier.md")

$(shared_context)"

# ------------------------------------------------------------------ summary
FILE_COUNT="$(wc -l <<<"$CHANGED" | tr -d ' ')"
{
  echo "range:    git diff $RANGE"
  echo "files:    $FILE_COUNT"
  echo "rails:    $([[ "$RUBY" == "1" ]] && echo "guidance loaded" || echo "n/a")"
  echo "guidance: $GUIDANCE_NOTE"
  echo "output:   $OUT"
} >&2

run_scanners() {
  local name pids=()
  for name in "${SCANNERS[@]}"; do
    ( "scanner_${name//-/_}" ) &
    pids+=($!)
  done
  wait "${pids[@]}"
}

if [[ "$DRY_RUN" == "1" ]]; then
  if [[ "$RUN_SCANNERS" == "1" ]]; then
    run_scanners
    for name in "${SCANNERS[@]}"; do printf '  %-13s %s\n' "$name" "$(cat "$SCAN_DIR/$name.status")" >&2; done
  fi
  log "(dry run — no agents launched)"
  exit 0
fi

# Run one isolated, read-only pi agent. Children skip extensions, skills, and
# prompt templates, and save no session; context files stay on.
run_agent() { # name prompt
  # shellcheck disable=SC2086
  timeout "$TIMEOUT" pi -ne -ns -np --no-session \
    --tools read,bash \
    ${MODEL:+--model "$MODEL"} \
    -p "$2" >"$OUT/$1.md" 2>"$OUT/$1.err"
  echo $? >"$OUT/$1.status"
}

# ---------------------------------------------------- stage 1: find candidates
log "stage 1:  reviewer + scanners"
run_agent review "$REVIEWER_PROMPT" &
REVIEW_PID=$!
[[ "$RUN_SCANNERS" == "1" ]] && run_scanners
wait "$REVIEW_PID"

REVIEW_OK=0
[[ "$(cat "$OUT/review.status" 2>/dev/null)" == "0" && -s "$OUT/review.md" ]] && REVIEW_OK=1

# Reviewer findings: split on the "# Vuln N:" headings the prompt requires.
if [[ "$REVIEW_OK" == "1" ]]; then
  awk -v dir="$OUT/candidates" '
    /^#+ Vuln [0-9]+:/ { n++; f = sprintf("%s/R%02d.md", dir, n) }
    n > 0 { print > f }
  ' "$OUT/review.md"
fi

# Scanner hits: one candidate per de-duplicated hit, most severe first. A hit
# within LINE_SLACK lines of a reviewer finding is attached to that finding as
# corroborating evidence instead, so one issue gets one verifier.
if [[ "$RUN_SCANNERS" == "1" ]]; then
  REVIEW_LOCS="$OUT/reviewer-locations.tsv"
  for c in "$OUT"/candidates/R*.md; do
    [[ -f "$c" ]] || continue
    awk -v c="$c" 'NR == 1 {
      if (match($0, /`[^`]+:[0-9]+/)) {
        loc = substr($0, RSTART + 1, RLENGTH - 1); i = match(loc, /:[0-9]+$/)
        print substr(loc, 1, i - 1) "\t" substr(loc, i + 1) "\t" c
      }
      exit }' "$c"
  done >"$REVIEW_LOCS"

  n=0
  while IFS=$'\t' read -r hfile hline hit; do
    rfile="$(awk -F'\t' -v f="$hfile" -v l="$hline" -v s="$LINE_SLACK" \
      '$1 == f && (l == 0 || ($2 - l <= s && l - $2 <= s)) { print $3; exit }' "$REVIEW_LOCS")"
    if [[ -n "$rfile" ]]; then
      jq -r '"* Corroborated by \(.tool): \(.rule) (\(.level)) at `\(.file):\(.line)`: \(.message)"' <<<"$hit" >>"$rfile"
      continue
    fi
    n=$((n + 1))
    jq -r '"# Scanner hit: \(.tool) \(.rule): `\(.file):\(.line)`\n\n* Tool: \(.tool)\n* Rule: \(.rule)\n* Level: \(.level)\n* Message: \(.message)"' \
      <<<"$hit" >"$OUT/candidates/$(printf 'S%02d' "$n").md"
  done < <(cat "$SCAN_DIR"/*.jsonl 2>/dev/null |
    jq -s -r 'unique_by([.tool, .rule, .file, .line])
              | sort_by({error: 0, warning: 1, note: 2}[.level] // 3)
              | .[] | "\(.file)\t\(.line // 0)\t\(tojson)"')
fi

CANDIDATES=()
for c in "$OUT"/candidates/R*.md "$OUT"/candidates/S*.md; do [[ -f "$c" ]] && CANDIDATES+=("$c"); done
OVERFLOW=()
if (( ${#CANDIDATES[@]} > MAX_CANDIDATES )); then
  OVERFLOW=("${CANDIDATES[@]:$MAX_CANDIDATES}")
  CANDIDATES=("${CANDIDATES[@]:0:$MAX_CANDIDATES}")
fi

source_of() { # candidate file -> "reviewer" or the scanner name
  local id; id="$(basename "$1" .md)"
  if [[ "$id" == R* ]]; then echo reviewer
  else sed -n 's/^\* Tool: //p' "$1" | head -1
  fi
}
title_of() { head -1 "$1" | sed -E 's/^#+ (Vuln [0-9]+|Scanner hit): //'; }

# -------------------------------------------------- stage 2: verify each one
verify_one() { # candidate file
  local c="$1" id prompt
  id="$(basename "$c" .md)"
  prompt="$VERIFIER_BASE

---

# Candidate to verify

Reported by: $(source_of "$c")

$(cat "$c")

---

# Context

Repository: $REPO_ROOT
Changes under review: git diff $RANGE
For one file: git diff $RANGE -- <file>

$RULES"
  run_agent "verdicts/$id" "$prompt"
}

log "stage 2:  verifying ${#CANDIDATES[@]} candidate(s) (${#OVERFLOW[@]} over cap), $JOBS at a time"
for c in "${CANDIDATES[@]}"; do
  while (( $(jobs -rp | wc -l) >= JOBS )); do wait -n 2>/dev/null || true; done
  verify_one "$c" &
done
wait

# ---------------------------------------------------------- stage 3: report
# Normalize a verdict (strip bold markers and an enclosing code fence).
normalize() {
  awk '{ lines[NR] = $0 }
       END {
         first = 1; while (first <= NR && lines[first] ~ /^[[:space:]]*$/) first++
         last = NR; while (last >= first && lines[last] ~ /^[[:space:]]*$/) last--
         if (lines[first] ~ /^```/ && lines[last] ~ /^```/ && last > first) { first++; last-- }
         for (i = first; i <= last; i++) print lines[i]
       }' "$1" |
    sed -E 's/^[*_[:space:]]*(VERDICT|CONFIDENCE|SEVERITY|TITLE|REASON)[*_]*:[*_[:space:]]*/\1: /'
}
field() { sed -n "s/^$1: //p" "$2" | head -1 | sed -E 's/[*_[:space:]]+$//'; }
score() { # "9", "9/10", "0.9" -> integer 0-10
  awk '{ if (match($0, /[0-9]+(\.[0-9]+)?/)) {
           s = substr($0, RSTART, RLENGTH); v = s + 0
           if (v <= 1 && index(s, ".")) v = v * 10
           printf "%d", v } else printf "0" }' <<<"$1"
}
sev_rank() { case "$1" in HIGH) echo 1 ;; MEDIUM) echo 2 ;; LOW) echo 3 ;; *) echo 4 ;; esac; }

FINDINGS_TSV="$OUT/findings.tsv"
: >"$FINDINGS_TSV"
UNVERIFIED=()
FILTERED=()

for c in "${CANDIDATES[@]}"; do
  id="$(basename "$c" .md)"
  v="$OUT/verdicts/$id"
  src="$(source_of "$c")"
  title="$(title_of "$c")"
  status="$(cat "$v.status" 2>/dev/null || echo '?')"
  if [[ "$status" != "0" || ! -s "$v.md" ]]; then
    UNVERIFIED+=("- **$title** — found by $src; verifier failed (status $status, see \`$v.err\`)")
    continue
  fi
  normalize "$v.md" >"$v.norm"
  verdict="$(field VERDICT "$v.norm" | tr '[:lower:]' '[:upper:]')"
  if [[ -z "$verdict" ]]; then
    UNVERIFIED+=("- **$title** — found by $src; verifier output unparseable (see \`$v.md\`)")
    continue
  fi
  conf="$(score "$(field CONFIDENCE "$v.norm")")"
  sev="$(field SEVERITY "$v.norm" | tr '[:lower:]' '[:upper:]')"
  vtitle="$(field TITLE "$v.norm")"
  reason="$(field REASON "$v.norm")"
  [[ -n "$vtitle" ]] && title="$vtitle"
  if [[ "$verdict" == CONFIRMED* ]] && (( conf >= MIN_CONFIDENCE )); then
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(sev_rank "$sev")" "$((10 - conf))" "$id" "$sev" "$conf" "$src" >>"$FINDINGS_TSV"
    printf '%s\n' "$title" >"$v.title"
  else
    FILTERED+=("- $title — ${conf}/10, found by $src: ${reason:-no reason given}")
  fi
done

for c in "${OVERFLOW[@]}"; do
  UNVERIFIED+=("- **$(title_of "$c")** — found by $(source_of "$c"); not verified (over --max-candidates $MAX_CANDIDATES)")
done

FINDING_COUNT="$(wc -l <"$FINDINGS_TSV" | tr -d ' ')"
REPORT="$OUT/report.md"
{
  echo "# Security Review"
  echo
  echo "_Range: \`git diff $RANGE\` · $FILE_COUNT file(s) · $((${#CANDIDATES[@]} + ${#OVERFLOW[@]})) candidate(s) → $FINDING_COUNT confirmed at ≥ $MIN_CONFIDENCE/10_"
  echo
  echo "## Findings ($FINDING_COUNT)"
  echo
  if [[ "$FINDING_COUNT" == "0" ]]; then
    echo "No confirmed security findings."
    echo
  fi
  n=0
  while IFS=$'\t' read -r _ _ id sev conf src; do
    n=$((n + 1))
    v="$OUT/verdicts/$id"
    echo "### $n. [${sev:-UNRATED}] $(cat "$v.title")"
    echo
    echo "_Found by $src · verifier confidence $conf/10_"
    echo
    sed -n '/^---$/,$p' "$v.norm" | sed '1d'
    echo
  done < <(sort -t$'\t' -k1,1n -k2,2n "$FINDINGS_TSV")

  if [[ ${#UNVERIFIED[@]} -gt 0 ]]; then
    echo "## Unverified (${#UNVERIFIED[@]})"
    echo
    echo "_Verification did not complete. Review these manually._"
    echo
    printf '%s\n' "${UNVERIFIED[@]}"
    echo
  fi

  if [[ ${#FILTERED[@]} -gt 0 ]]; then
    echo "## Filtered out (${#FILTERED[@]})"
    echo
    printf '%s\n' "${FILTERED[@]}"
    echo
  fi

  echo "## Coverage"
  echo
  if [[ "$REVIEW_OK" == "1" ]]; then
    reviewer_count="$(find "$OUT/candidates" -name 'R*.md' | wc -l | tr -d ' ')"
    if [[ "$reviewer_count" == "0" ]] && ! grep -qi 'no security findings' "$OUT/review.md"; then
      echo "- LLM reviewer: output had no \`# Vuln\` headings; read \`$OUT/review.md\` manually"
    else
      echo "- LLM reviewer: $reviewer_count candidate(s)"
    fi
  else
    echo "- LLM reviewer: **failed** (status $(cat "$OUT/review.status" 2>/dev/null || echo '?'), see \`$OUT/review.err\`)"
  fi
  if [[ "$RUN_SCANNERS" == "1" ]]; then
    for name in "${SCANNERS[@]}"; do
      echo "- $name: $(cat "$SCAN_DIR/$name.status" 2>/dev/null || echo 'no status')"
    done
  else
    echo "- scanners: disabled (--no-scanners)"
  fi
  echo "- Rails guidance: $([[ "$RUBY" == "1" ]] && echo loaded || echo "not applicable")"
  echo "- Project guidance: $GUIDANCE_NOTE"
  echo "- Artifacts: \`$OUT\`"
} >"$REPORT"

log "done:     $FINDING_COUNT confirmed, ${#FILTERED[@]} filtered, ${#UNVERIFIED[@]} unverified"
echo "$REPORT"
[[ "$REVIEW_OK" == "1" ]]
