#!/bin/bash
# Checks on bootstrap.sh that do not need AWS, so CI can run them on every pull request.
#
# Both of these guard against the same failure: a role that is created successfully but trusts
# the wrong thing, which only shows up later as a confusing "not authorized to perform
# sts:AssumeRoleWithWebIdentity" in an unrelated workflow.
#
#   1. repo_id() resolves the right numeric id, and fails loudly rather than returning something
#      unusable.
#   2. Every __PLACEHOLDER__ in a policy template is one render() actually substitutes.
#
# Usage: bash bootstrap/checks.sh   (needs network for the GitHub API)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP="${SCRIPT_DIR}/bootstrap.sh"
GITHUB_OWNER="${GITHUB_OWNER:-prudhvitej47}"

die() { printf 'DIE: %s\n' "$*" >&2; exit 1; }

fail=0
ok()   { printf 'ok    %s\n' "$*"; }
bad()  { printf 'FAIL  %s\n' "$*"; fail=1; }

check() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    ok "$label ($actual)"
  else
    bad "$label: expected $expected, got $actual"
  fi
}

# --- 1. repo_id ------------------------------------------------------------
# Pulled out of the script rather than copied, so this cannot drift from what actually runs.
eval "$(sed -n '/^repo_id() {/,/^}/p' "${BOOTSTRAP}")"

check "public repo is looked up"        1376721120 "$(repo_id interview-prep-app)"
check "public repo ignores a fallback"  1376725812 "$(repo_id interview-prep-infra 999)"
check "private repo uses the fallback"  1376725108 "$(repo_id interview-prep-content 1376725108 2>/dev/null)"

if (repo_id interview-prep-content >/dev/null 2>&1); then
  bad "private repo with no fallback should be fatal"
else
  ok "private repo with no fallback exits non-zero"
fi

if (repo_id interview-prep-content "not-a-number" >/dev/null 2>&1); then
  bad "a non-numeric id should be rejected"
else
  ok "a non-numeric id exits non-zero"
fi

# --- 2. every placeholder is rendered --------------------------------------
# The set of placeholders render() knows about, read from the sed expressions themselves.
# Newline-delimited strings rather than arrays, so this also runs on the bash 3.2 that ships
# with macOS, where mapfile does not exist.
handled="$(sed -n '/^render() {/,/^}/p' "${BOOTSTRAP}" | grep -oE '__[A-Z_]+__' | sort -u)"
[[ -n "${handled}" ]] || die "could not read any placeholders out of render()"

used="$(grep -ohE '__[A-Z_]+__' "${SCRIPT_DIR}"/*.json | sort -u)"
[[ -n "${used}" ]] || die "could not read any placeholders out of the policy templates"

while IFS= read -r placeholder; do
  [[ -n "${placeholder}" ]] || continue
  if printf '%s\n' "${handled}" | grep -qx "${placeholder}"; then
    ok "${placeholder} is substituted by render()"
  else
    bad "${placeholder} appears in a policy template but render() never substitutes it"
  fi
done <<< "${used}"

exit $fail
