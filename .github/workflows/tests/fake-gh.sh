#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Authors of KubeArmor

# A stand in for the "gh" CLI, used by trivy-scripts-test.sh so that the Trivy
# reporting scripts can be exercised without touching the GitHub API.
#
# Behaviour is driven by:
#   FAKE_GH_LOG          file every invocation is appended to
#   FAKE_GH_DIR          directory the captured "--body-file" contents land in
#   FAKE_GH_LABEL_MODE   ok | exists | forbidden  (default: ok)
#   FAKE_GH_ISSUE_LIST   file whose contents are returned by "gh issue list"

set -uo pipefail

printf '%s\n' "$*" >>"$FAKE_GH_LOG"

body_file=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "--body-file" ]; then
    body_file="$arg"
  fi
  prev="$arg"
done

capture_body() {
  [ -n "$body_file" ] || return 0
  cp "$body_file" "$FAKE_GH_DIR/last-body.md"
}

case "${1:-} ${2:-}" in
"label create")
  case "${FAKE_GH_LABEL_MODE:-ok}" in
  ok) exit 0 ;;
  exists)
    echo "HTTP 422: Validation Failed (https://api.github.com/repos/x/y/labels)" >&2
    echo "Label \"${3:-}\" already exists" >&2
    exit 1
    ;;
  *)
    echo "HTTP 403: Resource not accessible by integration" >&2
    exit 1
    ;;
  esac
  ;;
"issue list")
  cat "${FAKE_GH_ISSUE_LIST:-/dev/null}"
  ;;
"issue comment")
  capture_body
  echo "https://github.com/kubearmor/KubeArmor/issues/${3:-0}#issuecomment-1"
  ;;
"issue create")
  capture_body
  echo "https://github.com/kubearmor/KubeArmor/issues/4242"
  ;;
*)
  echo "fake-gh: unexpected command: $*" >&2
  exit 1
  ;;
esac
