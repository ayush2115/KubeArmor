#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Authors of KubeArmor

# Tests for trivy-summarize.sh and trivy-report-issue.sh.
#
# The GitHub API is never contacted: fake-gh.sh is put first on PATH and records
# what the scripts would have done. Run it with "./trivy-scripts-test.sh" from
# anywhere; it needs nothing beyond bash, awk and coreutils.

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKFLOWS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
SUMMARIZE="$WORKFLOWS_DIR/trivy-summarize.sh"
REPORT_ISSUE="$WORKFLOWS_DIR/trivy-report-issue.sh"

passed=0
failed=0
current=""

describe() {
  current="$1"
  echo
  echo "--- $current"
}

pass() {
  passed=$((passed + 1))
  echo "  ok: $1"
}

fail() {
  failed=$((failed + 1))
  echo "  FAIL: $1"
  shift
  for line in "$@"; do
    echo "      $line"
  done
}

assert_eq() {
  local what="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    pass "$what"
  else
    fail "$what" "expected: [$expected]" "actual:   [$actual]"
  fi
}

assert_contains() {
  local what="$1" haystack="$2" needle="$3"
  case "$haystack" in
  *"$needle"*) pass "$what" ;;
  *) fail "$what" "expected to find: [$needle]" ;;
  esac
}

assert_not_contains() {
  local what="$1" haystack="$2" needle="$3"
  case "$haystack" in
  *"$needle"*) fail "$what" "did not expect to find: [$needle]" ;;
  *) pass "$what" ;;
  esac
}

# ---------------------------------------------------------------------------
# trivy-summarize.sh
# ---------------------------------------------------------------------------

# Runs trivy-summarize.sh in a throwaway workspace. Sets the globals
# SUMMARY_OUT, SUMMARY_OUTPUTS, SUMMARY_JOB_SUMMARY, SUMMARY_MANIFEST and
# SUMMARY_RC for the assertions that follow.
run_summarize() {
  local components="$1"
  local workspace
  workspace="$(mktemp -d)"

  mkdir -p "$workspace/trivy-reports"
  shift
  # remaining arguments are "<component>:<report contents>" pairs
  local pair
  for pair in "$@"; do
    printf '%s\n' "${pair#*:}" >"$workspace/trivy-reports/${pair%%:*}.txt"
  done

  SUMMARY_OUTPUTS="$workspace/outputs"
  SUMMARY_JOB_SUMMARY="$workspace/job-summary"
  SUMMARY_MANIFEST="$workspace/trivy-reports/failed-components.tsv"
  : >"$SUMMARY_OUTPUTS"
  : >"$SUMMARY_JOB_SUMMARY"

  SUMMARY_OUT="$(
    cd "$workspace" &&
      TRIVY_COMPONENTS="$components" \
        TRIVY_REPORT_DIR="trivy-reports" \
        GITHUB_OUTPUT="$SUMMARY_OUTPUTS" \
        GITHUB_STEP_SUMMARY="$SUMMARY_JOB_SUMMARY" \
        "$SUMMARIZE" 2>&1
  )"
  SUMMARY_RC=$?
}

output_value() {
  awk -F= -v key="$1" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$SUMMARY_OUTPUTS"
}

describe "summarize: every component passes"
run_summarize "kubearmor-init|kubearmor/kubearmor-init:latest|success|true
kubearmor|kubearmor/kubearmor:latest|success|true"
assert_eq "exits 0" "0" "$SUMMARY_RC"
assert_eq "vulnerable is false" "false" "$(output_value vulnerable)"
assert_eq "no failed components" "" "$(output_value failed_components)"
assert_eq "manifest is empty" "0" "$(wc -c <"$SUMMARY_MANIFEST" | tr -d ' ')"
assert_contains "reports success" "$SUMMARY_OUT" "All Trivy scans passed."

describe "summarize: one component fails"
run_summarize "kubearmor-init|kubearmor/kubearmor-init:latest|success|true
kubearmor|kubearmor/kubearmor:latest|failure|true" \
  "kubearmor:CVE-2026-0001 openssl HIGH"
assert_eq "vulnerable is true" "true" "$(output_value vulnerable)"
assert_eq "failed component listed" "kubearmor" "$(output_value failed_components)"
assert_eq "manifest records name and image" \
  "kubearmor	kubearmor/kubearmor:latest" "$(cat "$SUMMARY_MANIFEST")"
assert_contains "report echoed to the log" "$SUMMARY_OUT" "CVE-2026-0001 openssl HIGH"
assert_contains "job summary has the table" "$(cat "$SUMMARY_JOB_SUMMARY")" \
  "| kubearmor | \`kubearmor/kubearmor:latest\` | :x: vulnerabilities found |"

describe "summarize: several components fail"
run_summarize "kubearmor-init|kubearmor/kubearmor-init:latest|failure|true
kubearmor|kubearmor/kubearmor:latest|failure|true
kubearmor-controller|kubearmor/kubearmor-controller:latest|failure|true"
assert_eq "all failures listed in order" \
  "kubearmor-init kubearmor kubearmor-controller" "$(output_value failed_components)"
assert_eq "manifest has one line per failure" "3" \
  "$(grep -c . "$SUMMARY_MANIFEST" | tr -d ' ')"

describe "summarize: components that were not built are skipped"
run_summarize "kubearmor|kubearmor/kubearmor:latest|success|true
kubearmor-operator|kubearmor/kubearmor-operator:latest||false"
assert_eq "vulnerable stays false" "false" "$(output_value vulnerable)"
assert_contains "skipped row rendered" "$(cat "$SUMMARY_JOB_SUMMARY")" \
  ":fast_forward: skipped (not built)"

describe "summarize: a scan that never produced an outcome is flagged, not counted"
run_summarize "kubearmor|kubearmor/kubearmor:latest||true"
assert_eq "vulnerable stays false" "false" "$(output_value vulnerable)"
assert_contains "warning row rendered" "$(cat "$SUMMARY_JOB_SUMMARY")" ":warning: scan did not run"

describe "summarize: UBI image names flow through"
run_summarize "kubearmor|kubearmor/kubearmor-ubi:latest|failure|true"
assert_eq "manifest carries the UBI image" \
  "kubearmor	kubearmor/kubearmor-ubi:latest" "$(cat "$SUMMARY_MANIFEST")"

# ---------------------------------------------------------------------------
# trivy-report-issue.sh
# ---------------------------------------------------------------------------

TITLE="[Trivy] Vulnerabilities detected in KubeArmor images on main"

# Runs trivy-report-issue.sh against fake-gh.sh. Sets REPORT_OUT, REPORT_RC,
# REPORT_LOG (every gh invocation) and REPORT_BODY (the body that was posted).
run_report_issue() {
  local manifest="$1" issue_list="$2" label_mode="$3"
  shift 3

  local workspace bin
  workspace="$(mktemp -d)"
  bin="$workspace/bin"
  mkdir -p "$bin" "$workspace/trivy-reports"
  cp "$TESTS_DIR/fake-gh.sh" "$bin/gh"
  chmod +x "$bin/gh"

  printf '%s\n' "$manifest" >"$workspace/trivy-reports/failed-components.tsv"
  printf '%s' "$issue_list" >"$workspace/issue-list"

  local pair
  for pair in "$@"; do
    printf '%s\n' "${pair#*:}" >"$workspace/trivy-reports/${pair%%:*}.txt"
  done

  REPORT_LOG="$workspace/gh.log"
  : >"$REPORT_LOG"
  REPORT_BODY_FILE="$workspace/last-body.md"

  REPORT_OUT="$(
    cd "$workspace" &&
      PATH="$bin:$PATH" \
        FAKE_GH_LOG="$REPORT_LOG" \
        FAKE_GH_DIR="$workspace" \
        FAKE_GH_LABEL_MODE="$label_mode" \
        FAKE_GH_ISSUE_LIST="$workspace/issue-list" \
        GH_TOKEN="fake" \
        GH_REPO="kubearmor/KubeArmor" \
        TRIVY_ISSUE_TITLE="$TITLE" \
        TRIVY_REPORT_DIR="trivy-reports" \
        TRIVY_ARTIFACT_NAME="trivy-reports" \
        GITHUB_SHA="0123456789abcdef0123456789abcdef01234567" \
        GITHUB_RUN_ID="99887766" \
        GITHUB_WORKFLOW="ci-trivy-scan" \
        "$REPORT_ISSUE" 2>&1
  )"
  REPORT_RC=$?
  REPORT_BODY=""
  [ -f "$REPORT_BODY_FILE" ] && REPORT_BODY="$(cat "$REPORT_BODY_FILE")"
  REPORT_CALLS="$(cat "$REPORT_LOG")"
}

MANIFEST_ONE="kubearmor	kubearmor/kubearmor:latest"

describe "report: opens a new issue when none is open"
run_report_issue "$MANIFEST_ONE" "" ok "kubearmor:CVE-2026-0001 openssl CRITICAL"
assert_eq "exits 0" "0" "$REPORT_RC"
assert_contains "creates the issue" "$REPORT_CALLS" "issue create --repo kubearmor/KubeArmor --title $TITLE"
assert_contains "applies both labels" "$REPORT_CALLS" "--label security,trivy"
assert_not_contains "does not comment" "$REPORT_CALLS" "issue comment"
assert_contains "body links the commit" "$REPORT_BODY" \
  "https://github.com/kubearmor/KubeArmor/commit/0123456789abcdef0123456789abcdef01234567"
assert_contains "body shows the short sha" "$REPORT_BODY" "0123456"
assert_contains "body links the workflow run" "$REPORT_BODY" \
  "https://github.com/kubearmor/KubeArmor/actions/runs/99887766"
assert_contains "body lists the affected image" "$REPORT_BODY" "- \`kubearmor/kubearmor:latest\`"
assert_contains "body embeds the report" "$REPORT_BODY" "CVE-2026-0001 openssl CRITICAL"
assert_contains "body mentions the artifact" "$REPORT_BODY" "trivy-reports\` artifact"

describe "report: creates both labels before using them"
run_report_issue "$MANIFEST_ONE" "" ok "kubearmor:x"
assert_contains "creates the security label" "$REPORT_CALLS" "label create security --repo kubearmor/KubeArmor"
assert_contains "creates the trivy label" "$REPORT_CALLS" "label create trivy --repo kubearmor/KubeArmor"

describe "report: labels that already exist are not an error"
run_report_issue "$MANIFEST_ONE" "" exists "kubearmor:x"
assert_eq "exits 0" "0" "$REPORT_RC"
assert_contains "still applies both labels" "$REPORT_CALLS" "--label security,trivy"

describe "report: unusable labels are dropped instead of failing the run"
run_report_issue "$MANIFEST_ONE" "" forbidden "kubearmor:x"
assert_eq "exits 0" "0" "$REPORT_RC"
assert_contains "warns about the label" "$REPORT_OUT" "could not ensure label 'security'"
assert_contains "still creates the issue" "$REPORT_CALLS" "issue create"
assert_not_contains "without any label" "$REPORT_CALLS" "--label"

describe "report: comments on the open issue instead of duplicating it"
run_report_issue "$MANIFEST_ONE" "17	$TITLE
21	Some unrelated open issue
" ok "kubearmor:CVE-2026-0002 zlib HIGH"
assert_eq "exits 0" "0" "$REPORT_RC"
assert_contains "comments on the tracking issue" "$REPORT_CALLS" "issue comment 17 --repo kubearmor/KubeArmor"
assert_not_contains "does not create a duplicate" "$REPORT_CALLS" "issue create"
assert_contains "comment marks it as a repeat" "$REPORT_BODY" "### Still failing on a newer commit"
assert_contains "comment carries the new commit" "$REPORT_BODY" "0123456"
assert_contains "comment carries the fresh report" "$REPORT_BODY" "CVE-2026-0002 zlib HIGH"

describe "report: only an exact title match is treated as the tracking issue"
run_report_issue "$MANIFEST_ONE" "17	$TITLE (UBI)
18	Re: $TITLE
" ok "kubearmor:x"
assert_contains "opens a new issue" "$REPORT_CALLS" "issue create"
assert_not_contains "ignores the near matches" "$REPORT_CALLS" "issue comment"

describe "report: matches the tracking issue anywhere in the listing"
run_report_issue "$MANIFEST_ONE" "3	Another issue
17	$TITLE
" ok "kubearmor:x"
assert_contains "comments on issue 17" "$REPORT_CALLS" "issue comment 17"

describe "report: an oversized report is truncated to fit the GitHub body limit"
big="$(awk 'BEGIN { for (i = 0; i < 4000; i++) print "CVE-2026-" i " some-package HIGH 1.0.0 1.0.1" }')"
run_report_issue "$MANIFEST_ONE" "" ok "kubearmor:$big"
assert_eq "exits 0" "0" "$REPORT_RC"
body_size="$(printf '%s' "$REPORT_BODY" | wc -c | tr -d ' ')"
if [ "$body_size" -lt 65536 ]; then
  pass "body stays under the 65536 character limit ($body_size)"
else
  fail "body stays under the 65536 character limit" "actual size: $body_size"
fi
assert_contains "explains the truncation" "$REPORT_BODY" "truncated at"
assert_contains "points at the artifact" "$REPORT_BODY" "download the \"trivy-reports\" artifact"
assert_contains "keeps the beginning of the report" "$REPORT_BODY" "CVE-2026-0 some-package HIGH"

describe "report: a box drawn report is measured in bytes, not characters"
# Trivy draws its table with three byte box characters, so a report that looks
# small when counted in characters can still be far too large for the API.
wide="$(awk 'BEGIN { for (i = 0; i < 4000; i++) print "│ libssl3 │ CVE-2026-" i " │ HIGH │ 3.0.15 │ 3.0.16 │" }')"
run_report_issue "$MANIFEST_ONE" "" ok "kubearmor:$wide"
assert_eq "exits 0" "0" "$REPORT_RC"
body_size="$(printf '%s' "$REPORT_BODY" | wc -c | tr -d ' ')"
if [ "$body_size" -lt 65536 ]; then
  pass "body stays under the 65536 byte limit ($body_size)"
else
  fail "body stays under the 65536 byte limit" "actual size: $body_size bytes"
fi
assert_contains "box characters survive intact" "$REPORT_BODY" "│ libssl3 │ CVE-2026-0 │"
if printf '%s' "$REPORT_BODY" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1; then
  pass "body is still valid UTF-8 after truncation"
else
  fail "body is still valid UTF-8 after truncation" "iconv rejected the truncated body"
fi
if [ -z "$(printf '%s' "$REPORT_BODY" | sed -n 's/.*\(│ libssl3 │ CVE-2026-[0-9]*\)$/\1/p')" ]; then
  pass "no half written table row is left at the cut"
else
  fail "no half written table row is left at the cut"
fi

describe "report: several failing components each get their own section"
run_report_issue "kubearmor	kubearmor/kubearmor:latest
kubearmor-init	kubearmor/kubearmor-init:latest" "" ok \
  "kubearmor:main image finding" "kubearmor-init:init image finding"
assert_contains "lists the first image" "$REPORT_BODY" "- \`kubearmor/kubearmor:latest\`"
assert_contains "lists the second image" "$REPORT_BODY" "- \`kubearmor/kubearmor-init:latest\`"
assert_contains "embeds the first report" "$REPORT_BODY" "main image finding"
assert_contains "embeds the second report" "$REPORT_BODY" "init image finding"

describe "report: a missing report file does not break the issue"
run_report_issue "$MANIFEST_ONE" "" ok
assert_eq "exits 0" "0" "$REPORT_RC"
assert_contains "says the report is missing" "$REPORT_BODY" "no report was captured"
assert_contains "still creates the issue" "$REPORT_CALLS" "issue create"

describe "report: nothing to do when no component failed"
run_report_issue "" "" ok
assert_eq "exits 0" "0" "$REPORT_RC"
assert_contains "explains why" "$REPORT_OUT" "nothing to report"
assert_eq "no gh calls at all" "" "$REPORT_CALLS"

# ---------------------------------------------------------------------------
# both scripts together, the way the workflow chains them
# ---------------------------------------------------------------------------

describe "end to end: summarize hands the failing components over to the reporter"
e2e="$(mktemp -d)"
mkdir -p "$e2e/trivy-reports" "$e2e/bin"
cp "$TESTS_DIR/fake-gh.sh" "$e2e/bin/gh"
chmod +x "$e2e/bin/gh"
cat >"$e2e/trivy-reports/kubearmor.txt" <<'REPORT'
kubearmor.tar (debian 12.11)
============================
Total: 1 (HIGH: 1, CRITICAL: 0)

| Library | Vulnerability  | Severity | Installed | Fixed  |
|---------|----------------|----------|-----------|--------|
| libssl3 | CVE-2026-11111 | HIGH     | 3.0.15-1  | 3.0.16 |
REPORT
: >"$e2e/issue-list"
: >"$e2e/gh.log"

e2e_out="$(
  cd "$e2e" &&
    TRIVY_COMPONENTS="kubearmor-init|kubearmor/kubearmor-init:latest|success|true
kubearmor|kubearmor/kubearmor:latest|failure|true
kubearmor-operator|kubearmor/kubearmor-operator:latest||false" \
      TRIVY_REPORT_DIR="trivy-reports" \
      GITHUB_OUTPUT="$e2e/outputs" \
      "$SUMMARIZE" >/dev/null 2>&1 &&
    PATH="$e2e/bin:$PATH" \
      FAKE_GH_LOG="$e2e/gh.log" \
      FAKE_GH_DIR="$e2e" \
      FAKE_GH_ISSUE_LIST="$e2e/issue-list" \
      GH_TOKEN="fake" \
      GH_REPO="kubearmor/KubeArmor" \
      TRIVY_ISSUE_TITLE="$TITLE" \
      TRIVY_REPORT_DIR="trivy-reports" \
      GITHUB_SHA="0123456789abcdef0123456789abcdef01234567" \
      GITHUB_RUN_ID="99887766" \
      "$REPORT_ISSUE" 2>&1
)"
e2e_rc=$?
assert_eq "both scripts succeed" "0" "$e2e_rc"
assert_contains "an issue is opened" "$(cat "$e2e/gh.log")" "issue create"
assert_contains "for the failing image only" "$(cat "$e2e/last-body.md")" \
  "- \`kubearmor/kubearmor:latest\`"
assert_not_contains "the passing image is not listed" "$(cat "$e2e/last-body.md")" \
  "kubearmor/kubearmor-init:latest"
assert_contains "the real report is carried across" "$(cat "$e2e/last-body.md")" "CVE-2026-11111"
assert_contains "issue url reported" "$e2e_out" "issues/4242"

echo
echo "=============================================="
echo "passed: $passed   failed: $failed"
echo "=============================================="
[ "$failed" -eq 0 ]
