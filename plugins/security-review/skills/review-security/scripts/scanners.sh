# shellcheck shell=bash
# Deterministic scanners for review-security.sh. Sourced, not executed.
#
# Each scanner_<tool> function:
#   - decides whether it applies to this diff and whether its tool is installed
#   - writes normalized hits, one JSON object per line, to $SCAN_DIR/<tool>.jsonl:
#       {"tool","rule","level","file","line","message"}
#     keeping only hits on (or within $LINE_SLACK lines of) lines this diff added
#   - writes a one-line human summary to $SCAN_DIR/<tool>.status
#
# Globals provided by the caller:
#   REPO_ROOT RANGE SCAN_DIR ADDED_TSV CHANGED_JSON SCANNER_TIMEOUT DRY_RUN
#   SCAN_FILES (array of changed files that still exist)

LINE_SLACK="${LINE_SLACK:-3}"

scan_status() { printf '%s\n' "$2" >"$SCAN_DIR/$1.status"; }

# True when any changed file matches the extended regex $1.
changed_match() { printf '%s\n' "${SCAN_FILES[@]}" | grep -qE "$1"; }

# Changed files matching the extended regex $1, one per line.
changed_files() { printf '%s\n' "${SCAN_FILES[@]}" | grep -E "$1"; }

# Keep normalized hits that land near an added line. With scope "file", keep
# every hit in a file the diff added lines to (for file-level audits).
filter_hits() { # scope < jsonl
  jq -c --slurpfile ch "$CHANGED_JSON" --arg scope "$1" --argjson slack "$LINE_SLACK" '
    ($ch[0][.file] // null) as $lines
    | (.line // 0) as $l
    | select($lines != null)
    | select($scope == "file" or $l == 0
             or any($lines[]; . >= ($l - $slack) and . <= ($l + $slack)))'
}

# Normalize a SARIF log into hit objects.
sarif_hits() { # tool < sarif
  jq -c --arg tool "$1" --arg root "$REPO_ROOT/" '
    .runs[]? | .results[]? | {
      tool: $tool,
      rule: (.ruleId // "unknown"),
      level: (.level // "warning"),
      file: ((.locations[0].physicalLocation.artifactLocation.uri // "")
             | sub("^file://"; "") | ltrimstr($root)),
      line: (.locations[0].physicalLocation.region.startLine // 0),
      message: ((.message.text // "") | gsub("\\s+"; " ") | .[0:500])
    }'
}

# Record the outcome of a scanner run: count filtered hits or report failure.
finish_scan() { # tool exit_status total_hits
  local tool="$1" rc="$2" total="$3" kept
  if [[ "$rc" == "124" ]]; then
    scan_status "$tool" "failed: timed out after ${SCANNER_TIMEOUT}s"
    return
  fi
  kept="$(wc -l <"$SCAN_DIR/$tool.jsonl" | tr -d ' ')"
  scan_status "$tool" "$kept hit(s) on changed lines ($total total)"
}

fail_scan() { # tool exit_status
  if [[ "$2" == "124" ]]; then
    scan_status "$1" "failed: timed out after ${SCANNER_TIMEOUT}s"
  else
    scan_status "$1" "failed: exit $2 (see $SCAN_DIR/$1.err)"
  fi
}

# --------------------------------------------------------------- gitleaks
# Scans only the lines this diff adds. Secrets are redacted in all output.
scanner_gitleaks() {
  local tool=gitleaks skip='(^|/)(Gemfile\.lock|package-lock\.json|yarn\.lock|pnpm-lock\.yaml|Cargo\.lock|poetry\.lock|composer\.lock|go\.sum)$|\.min\.(js|css)$|\.map$'
  command -v gitleaks >/dev/null || { scan_status $tool "skipped: not installed (brew install gitleaks)"; return; }
  [[ -s "$ADDED_TSV" ]] || { scan_status $tool "skipped: no added lines"; return; }
  [[ "$DRY_RUN" == "1" ]] && { scan_status $tool "would run: gitleaks stdin on added lines"; return; }

  local index="$SCAN_DIR/$tool.index" raw="$SCAN_DIR/$tool.json" rc total
  awk -F'\t' -v skip="$skip" '$1 !~ skip' "$ADDED_TSV" >"$index"
  cut -f3- "$index" |
    timeout "$SCANNER_TIMEOUT" gitleaks stdin --no-banner --redact --exit-code 0 \
      --log-level error -f json -r "$raw" 2>"$SCAN_DIR/$tool.err"
  rc=$?
  [[ "$rc" == "0" || "$rc" == "124" ]] || { fail_scan $tool "$rc"; return; }
  [[ -s "$raw" ]] || echo '[]' >"$raw"

  total="$(jq 'length' "$raw" 2>/dev/null || echo 0)"
  # Map each hit's stdin line number back to file:line via the index.
  jq -r '.[] | [.StartLine, .RuleID, (.Description // "")] | @tsv' "$raw" |
    awk -F'\t' 'NR == FNR { f[NR] = $1; l[NR] = $2; next }
                { print f[$1] "\t" l[$1] "\t" $2 "\t" $3 }' "$index" - |
    jq -R -c 'split("\t") | {tool: "gitleaks", rule: .[2], level: "error",
              file: .[0], line: (.[1] | tonumber), message: ("Possible secret: " + .[3])}' \
      >"$SCAN_DIR/$tool.jsonl"
  finish_scan $tool "$rc" "$total"
}

# --------------------------------------------------------------- brakeman
scanner_brakeman() {
  local tool=brakeman cmd=()
  if [[ ! -f config/application.rb ]] || ! grep -qE '^    rails ' Gemfile.lock 2>/dev/null; then
    scan_status $tool "skipped: not a Rails app"; return
  fi
  changed_match '\.(rb|erb|haml|slim|rake|jbuilder|builder)$' ||
    { scan_status $tool "skipped: no Ruby or view files changed"; return; }
  if grep -qE '^    brakeman ' Gemfile.lock && command -v bundle >/dev/null; then
    cmd=(bundle exec brakeman)
  elif command -v brakeman >/dev/null; then
    cmd=(brakeman)
  else
    scan_status $tool "skipped: not installed (gem install brakeman, or add it to the Gemfile)"; return
  fi
  [[ "$DRY_RUN" == "1" ]] && { scan_status $tool "would run: ${cmd[*]} -w2 (filtered to changed lines)"; return; }

  local raw="$SCAN_DIR/$tool.sarif" rc
  timeout "$SCANNER_TIMEOUT" "${cmd[@]}" -q --no-pager --no-exit-on-warn --no-exit-on-error \
    -w2 -f sarif -o "$raw" . >/dev/null 2>"$SCAN_DIR/$tool.err"
  rc=$?
  [[ -s "$raw" ]] || { fail_scan $tool "$rc"; return; }
  sarif_hits brakeman <"$raw" | filter_hits line >"$SCAN_DIR/$tool.jsonl"
  finish_scan $tool "$rc" "$(sarif_hits brakeman <"$raw" | wc -l | tr -d ' ')"
}

# ----------------------------------------------------------------- zizmor
scanner_zizmor() {
  local tool=zizmor files
  files="$(changed_files '(^|/)\.github/workflows/[^/]+\.ya?ml$|(^|/)action\.ya?ml$')"
  [[ -n "$files" ]] || { scan_status $tool "skipped: no workflow or action files changed"; return; }
  command -v zizmor >/dev/null || { scan_status $tool "skipped: not installed (brew install zizmor)"; return; }
  [[ "$DRY_RUN" == "1" ]] && { scan_status $tool "would run: zizmor --offline on $(wc -l <<<"$files" | tr -d ' ') file(s)"; return; }

  local raw="$SCAN_DIR/$tool.sarif" rc targets=()
  mapfile -t targets <<<"$files"
  timeout "$SCANNER_TIMEOUT" zizmor --offline --no-progress --min-severity medium \
    --format sarif "${targets[@]}" >"$raw" 2>"$SCAN_DIR/$tool.err"
  rc=$?
  # zizmor exits non-zero when it finds issues; trust the SARIF if present.
  jq -e '.runs' "$raw" >/dev/null 2>&1 || { fail_scan $tool "$rc"; return; }
  sarif_hits zizmor <"$raw" | filter_hits file >"$SCAN_DIR/$tool.jsonl"
  finish_scan $tool "$rc" "$(sarif_hits zizmor <"$raw" | wc -l | tr -d ' ')"
}

# ---------------------------------------------------------------- semgrep
# Optional. Uses the registry ruleset in $SECURITY_REVIEW_SEMGREP_CONFIG.
scanner_semgrep() {
  local tool=semgrep config="${SECURITY_REVIEW_SEMGREP_CONFIG:-p/default}"
  semgrep --version >/dev/null 2>&1 || { scan_status $tool "skipped: not installed"; return; }
  [[ ${#SCAN_FILES[@]} -gt 0 ]] || { scan_status $tool "skipped: no files to scan"; return; }
  [[ "$DRY_RUN" == "1" ]] && { scan_status $tool "would run: semgrep --config $config on ${#SCAN_FILES[@]} file(s)"; return; }

  local raw="$SCAN_DIR/$tool.sarif" rc
  timeout "$SCANNER_TIMEOUT" semgrep scan --config "$config" --metrics off --quiet \
    --sarif --output "$raw" -- "${SCAN_FILES[@]}" >/dev/null 2>"$SCAN_DIR/$tool.err"
  rc=$?
  jq -e '.runs' "$raw" >/dev/null 2>&1 || { fail_scan $tool "$rc"; return; }
  sarif_hits semgrep <"$raw" | filter_hits line >"$SCAN_DIR/$tool.jsonl"
  finish_scan $tool "$rc" "$(sarif_hits semgrep <"$raw" | wc -l | tr -d ' ')"
}

# ----------------------------------------------------------- bundle-audit
# Reports advisories only for gems whose Gemfile.lock entries this diff adds.
scanner_bundle_audit() {
  local tool=bundle-audit cmd=()
  changed_match '^Gemfile\.lock$' || { scan_status $tool "skipped: Gemfile.lock unchanged"; return; }
  if command -v bundle-audit >/dev/null; then cmd=(bundle-audit)
  elif command -v bundler-audit >/dev/null; then cmd=(bundler-audit)
  elif grep -qE '^    bundler-audit ' Gemfile.lock 2>/dev/null && command -v bundle >/dev/null; then cmd=(bundle exec bundle-audit)
  else scan_status $tool "skipped: not installed (gem install bundler-audit)"; return
  fi
  [[ "$DRY_RUN" == "1" ]] && { scan_status $tool "would run: ${cmd[*]} check --update (gems added by this diff)"; return; }

  local raw="$SCAN_DIR/$tool.txt" rc gems
  timeout "$SCANNER_TIMEOUT" "${cmd[@]}" check --update >"$raw" 2>"$SCAN_DIR/$tool.err"
  rc=$?
  # 0 = clean, 1 = vulnerabilities found; anything else is a real failure.
  [[ "$rc" == "0" || "$rc" == "1" ]] || { fail_scan $tool "$rc"; return; }

  # "name<TAB>line" for gem specs added to Gemfile.lock (four-space indent).
  gems="$(awk -F'\t' '$1 == "Gemfile.lock" && match($3, /^    [A-Za-z0-9_.-]+ \(/) {
            name = substr($3, 5, RLENGTH - 6); print name "\t" $2 }' "$ADDED_TSV")"
  awk -v gems="$gems" '
    BEGIN { n = split(gems, rows, "\n"); for (i = 1; i <= n; i++) { split(rows[i], p, "\t"); line[p[1]] = p[2] } }
    /^Name: /        { name = substr($0, 7) }
    /^Criticality: / { crit = substr($0, 14) }
    /^(CVE|GHSA): /  { if (!id) id = substr($0, index($0, " ") + 1) }
    /^Title: /       { title = substr($0, 8) }
    /^Solution: /    { sol = substr($0, 11) }
    /^$/ { if (name != "" && name in line) print name "\t" line[name] "\t" crit "\t" id "\t" title "\t" sol
           name = crit = id = title = sol = "" }
    END  { if (name != "" && name in line) print name "\t" line[name] "\t" crit "\t" id "\t" title "\t" sol }' "$raw" |
    jq -R -c 'split("\t") | {tool: "bundle-audit", rule: (.[3] // "advisory"),
              level: (if (.[2] | ascii_downcase) == "high" or (.[2] | ascii_downcase) == "critical" then "error" else "warning" end),
              file: "Gemfile.lock", line: (.[1] | tonumber),
              message: ("\(.[0]): \(.[4]) (criticality: \(.[2]); \(.[5]))")}' \
      >"$SCAN_DIR/$tool.jsonl"
  finish_scan $tool 0 "$(grep -c '^Name: ' "$raw")"
}

# -------------------------------------------------------------- npm audit
# Reports advisories only for packages whose lockfile entries this diff adds.
scanner_npm_audit() {
  local tool=npm-audit locks
  locks="$(changed_files '(^|/)package-lock\.json$')"
  [[ -n "$locks" ]] || { scan_status $tool "skipped: package-lock.json unchanged"; return; }
  command -v npm >/dev/null || { scan_status $tool "skipped: npm not installed"; return; }
  [[ "$DRY_RUN" == "1" ]] && { scan_status $tool "would run: npm audit --package-lock-only on $(wc -l <<<"$locks" | tr -d ' ') lockfile(s)"; return; }

  local lock dir slug raw rc total=0 failed=""
  : >"$SCAN_DIR/$tool.jsonl"
  while IFS= read -r lock; do
    dir="$(dirname "$lock")"
    slug="${dir//\//_}"; [[ "$dir" == "." ]] && slug=root
    raw="$SCAN_DIR/$tool.$slug.json"
    (cd "$dir" && timeout "$SCANNER_TIMEOUT" npm audit --json --package-lock-only) >"$raw" 2>>"$SCAN_DIR/$tool.err"
    rc=$?
    jq -e '.vulnerabilities' "$raw" >/dev/null 2>&1 || { failed="exit $rc in $dir"; continue; }
    total=$((total + $(jq '.vulnerabilities | length' "$raw")))
    # Package names (with the added line) from lockfile object keys this diff
    # adds: "node_modules/a/node_modules/@s/b": { -> @s/b (v1 keys pass through).
    awk -F'\t' -v f="$lock" '$1 == f && match($3, /"[^"]+": \{/) {
           key = substr($3, RSTART + 1, RLENGTH - 5); sub(/.*node_modules\//, "", key); print key "\t" $2 }' "$ADDED_TSV" |
      jq -R -s -c --slurpfile audit "$raw" --arg file "$lock" '
        (split("\n") | map(select(length > 0) | split("\t") | {key: .[0], value: (.[1] | tonumber)})
         | reverse | from_entries) as $added
        | $audit[0].vulnerabilities | to_entries[]
        | select(.value.severity != "low" and .value.severity != "info")
        | select($added[.key] != null)
        | {tool: "npm-audit", rule: .value.severity,
           level: (if .value.severity == "critical" or .value.severity == "high" then "error" else "warning" end),
           file: $file, line: $added[.key],
           message: ("\(.key): " + ([.value.via[] | if type == "object" then "\(.title) \(.url)" else "via \(.)" end] | join("; ")) | .[0:500])}' \
        >>"$SCAN_DIR/$tool.jsonl"
  done <<<"$locks"
  if [[ -n "$failed" && ! -s "$SCAN_DIR/$tool.jsonl" && "$total" == "0" ]]; then
    scan_status $tool "failed: $failed (see $SCAN_DIR/$tool.err)"; return
  fi
  finish_scan $tool 0 "$total"
}

# Tool names double as status/hit file names; functions are scanner_<name//-/_>.
# shellcheck disable=SC2034  # used by review-security.sh
SCANNERS=(gitleaks brakeman zizmor semgrep bundle-audit npm-audit)
