#!/bin/bash
#
# Tests for lib/external-secret-owner.sh.
#
# Run: bash tests/external_secret_owner_test.sh
#
# Each test runs in its own subshell with a stub kubectl first on PATH. The stub
# records its arguments in STUB_DIR/kubectl.calls, and run_test passes that file
# to the test as its first argument. STUB_UID sets the UID that
# `kubectl get job` prints, STUB_GET_EXIT sets its exit code, and
# STUB_PATCH_EXIT sets the exit code of `kubectl patch`. The script prints PASS
# or FAIL for each test and exits 1 when a test fails.

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/lib/external-secret-owner.sh"

failures=0

# make_stub DIR writes the stub kubectl into DIR.
make_stub() {
  cat >"$1/kubectl" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"$STUB_DIR/kubectl.calls"
case "$1" in
  get)
    printf '%s' "${STUB_UID-}"
    exit "${STUB_GET_EXIT:-0}"
    ;;
  patch)
    exit "${STUB_PATCH_EXIT:-0}"
    ;;
esac
EOF
  chmod +x "$1/kubectl"
}

# run_test NAME FUNCTION runs FUNCTION in a subshell with a new stub directory.
run_test() {
  local name="$1" fn="$2"
  if (
    STUB_DIR="$(mktemp -d)"
    export STUB_DIR
    trap 'rm -rf "$STUB_DIR"' EXIT
    make_stub "$STUB_DIR"
    PATH="$STUB_DIR:$PATH"
    "$fn" "$STUB_DIR/kubectl.calls"
  ); then
    echo "PASS ${name}"
  else
    echo "FAIL ${name}"
    failures=$((failures + 1))
  fi
}

test_patches_the_owner_reference_with_the_job_uid() {
  local calls="$1"
  export STUB_UID="0f6c4c2e-1111-4222-8333-944455556666"
  local out
  out="$(set_external_secret_owner my-job-12-abcdefgh 2>&1)" || return 1
  [[ $out == "ExternalSecret my-job-12-abcdefgh is owned by job my-job-12-abcdefgh" ]] || return 1
  grep -q -F 'get job my-job-12-abcdefgh --output=jsonpath={.metadata.uid}' "$calls" || return 1
  grep -q -F 'patch externalsecrets.external-secrets.io my-job-12-abcdefgh --type=merge --patch {"metadata":{"ownerReferences":[{"apiVersion":"batch/v1","kind":"Job","name":"my-job-12-abcdefgh","uid":"0f6c4c2e-1111-4222-8333-944455556666","blockOwnerDeletion":false}]}}' "$calls"
}

test_get_failure_warns_and_does_not_patch() {
  local calls="$1"
  export STUB_UID="Error from server (NotFound)" STUB_GET_EXIT=1
  local out
  out="$(set_external_secret_owner my-job 2>&1)" || return 1
  [[ $out == *"Warning: cannot read the UID of job my-job"* ]] || return 1
  ! grep -q '^patch' "$calls"
}

test_empty_uid_warns_and_does_not_patch() {
  local calls="$1"
  export STUB_UID=""
  local out
  out="$(set_external_secret_owner my-job 2>&1)" || return 1
  [[ $out == *"Warning: cannot read the UID of job my-job"* ]] || return 1
  ! grep -q '^patch' "$calls"
}

test_patch_failure_warns_and_returns_zero() {
  local calls="$1"
  export STUB_UID="uid-1" STUB_PATCH_EXIT=1
  local out
  out="$(set_external_secret_owner my-job 2>&1)" || return 1
  [[ $out == "Warning: cannot set job my-job as the owner of ExternalSecret my-job" ]]
}

run_test "patches the owner reference with the job UID" test_patches_the_owner_reference_with_the_job_uid
run_test "a failed get warns and does not patch" test_get_failure_warns_and_does_not_patch
run_test "an empty UID warns and does not patch" test_empty_uid_warns_and_does_not_patch
run_test "a failed patch warns and returns 0" test_patch_failure_warns_and_returns_zero

if ((failures > 0)); then
  echo "${failures} test(s) failed"
  exit 1
fi
echo "all tests passed"
