#!/bin/bash
#
# Tests for the mount-emptydir and automount-service-account-token options in
# lib/job.jsonnet.
#
# Run: bash tests/job_render_test.sh
#
# Each test renders lib/job.jsonnet or lib/externalsecret.jsonnet with jsonnet
# and checks the result with jq. The plugin options go in as the
# BUILDKITE_PLUGIN_K8S_* variables that the agent sets, in the agentEnv
# argument. The script prints PASS or FAIL for each test and exits 1 when a
# test fails.

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

for tool in jsonnet jq; do
  if ! command -v "$tool" >/dev/null; then
    echo "FAIL: $tool is not on PATH"
    exit 1
  fi
done

# base_env prints the agent variables that a render needs, as JSON.
base_env() {
  jq -n '{
    BUILDKITE_PLUGIN_K8S_IMAGE: "alpine:3",
    BUILDKITE_AGENT_NAME: "agent",
    BUILDKITE_ORGANIZATION_SLUG: "org",
    BUILDKITE_PIPELINE_SLUG: "pipeline",
    BUILDKITE_BUILD_PATH: "/buildkite/builds",
    BUILDKITE_COMMAND: "true",
    BUILDKITE_JOB_ID: "job",
    BUILDKITE_COMMIT: "commit",
    BUILDKITE_BRANCH: "branch",
    BUILDKITE_BUILD_URL: "url",
    BUILDKITE_BUILD_NUMBER: "1",
    BUILDKITE_PIPELINE_NAME: "pipeline",
    BUILDKITE_BUILD_ID: "build",
    BUILDKITE_JOB_URL: "url",
    BUILDKITE_LABEL: "label",
    BUILDKITE_BUILD_CREATOR: "creator",
    BUILDKITE_BUILD_CREATOR_EMAIL: "creator@example.com",
    BUILDKITE_MESSAGE: "message",
    BUILDKITE_REPO: "repo",
    BUILDKITE_AGENT_ID: "agent-id",
    BUILDKITE_TIMEOUT: "10",
    BUILDKITE_SOURCE: "ui",
    BUILDKITE_STEP_ID: "step",
    BUILDKITE_STEP_KEY: "key",
    BUILDKITE_PLUGIN_K8S_CLUSTER_STORE: "store",
    BUILDKITE_PLUGIN_K8S_EXTERNAL_SECRETS: "user:secret/path:user"
  }'
}

# render <file> <extra JSON object> renders lib/<file> with the base variables
# and the extra variables, and prints the result.
render() {
  local env_json
  env_json="$(base_env | jq -c --argjson extra "$2" '. + $extra')"
  jsonnet --tla-str jobName=job --tla-str stepEnvFile= \
    --tla-code "agentEnv=${env_json}" "${repo_root}/lib/$1"
}

fails=0

# expect_eq <description> <want> <got>
expect_eq() {
  if [[ "$2" != "$3" ]]; then
    printf '    %s: want %q, got %q\n' "$1" "$2" "$3"
    fails=$((fails + 1))
  fi
}

# pod_query <extra JSON object> <jq filter> renders the Job and applies the
# filter to its pod spec.
pod_query() {
  render job.jsonnet "$1" | jq -c ".spec.template.spec | $2"
}

emptydir_volumes='[.volumes[] | select(.name | startswith("emptydir-"))]'
emptydir_mounts='[.containers[] | select(.name == "step") | .volumeMounts[]
  | select(.name | startswith("emptydir-"))]'

test_no_options() {
  expect_eq "volumes" '[]' "$(pod_query '{}' "$emptydir_volumes")"
  expect_eq "mounts" '[]' "$(pod_query '{}' "$emptydir_mounts")"
  expect_eq "automount field" 'false' "$(pod_query '{}' 'has("automountServiceAccountToken")')"
  ((fails == 0))
}

test_emptydir_string() {
  local opts='{"BUILDKITE_PLUGIN_K8S_MOUNT_EMPTYDIR": "/scratch"}'
  expect_eq "volumes" '[{"emptyDir":{},"name":"emptydir-0"}]' \
    "$(pod_query "$opts" "$emptydir_volumes")"
  expect_eq "mounts" '[{"mountPath":"/scratch","name":"emptydir-0"}]' \
    "$(pod_query "$opts" "$emptydir_mounts")"
  ((fails == 0))
}

test_emptydir_array() {
  local opts='{"BUILDKITE_PLUGIN_K8S_MOUNT_EMPTYDIR_0": "/a", "BUILDKITE_PLUGIN_K8S_MOUNT_EMPTYDIR_1": "/b"}'
  expect_eq "volumes" '[{"emptyDir":{},"name":"emptydir-0"},{"emptyDir":{},"name":"emptydir-1"}]' \
    "$(pod_query "$opts" "$emptydir_volumes")"
  expect_eq "mounts" '[{"mountPath":"/a","name":"emptydir-0"},{"mountPath":"/b","name":"emptydir-1"}]' \
    "$(pod_query "$opts" "$emptydir_mounts")"
  ((fails == 0))
}

test_emptydir_numeric_order() {
  local opts='{"BUILDKITE_PLUGIN_K8S_MOUNT_EMPTYDIR_10": "/ten", "BUILDKITE_PLUGIN_K8S_MOUNT_EMPTYDIR_2": "/two"}'
  expect_eq "mount order" '["/two","/ten"]' \
    "$(pod_query "$opts" "${emptydir_mounts} | map(.mountPath)")"
  ((fails == 0))
}

test_emptydir_empty_entry_dropped() {
  local opts='{"BUILDKITE_PLUGIN_K8S_MOUNT_EMPTYDIR_0": "", "BUILDKITE_PLUGIN_K8S_MOUNT_EMPTYDIR_1": "/b"}'
  expect_eq "mounts" '[{"mountPath":"/b","name":"emptydir-0"}]' \
    "$(pod_query "$opts" "$emptydir_mounts")"
  ((fails == 0))
}

test_emptydir_other_prefix_ignored() {
  local opts='{"BUILDKITE_PLUGIN_K8S_MOUNT_EMPTYDIR_MEDIUM": "Memory"}'
  expect_eq "volumes" '[]' "$(pod_query "$opts" "$emptydir_volumes")"
  expect_eq "mounts" '[]' "$(pod_query "$opts" "$emptydir_mounts")"
  ((fails == 0))
}

test_emptydir_keeps_hostpath() {
  local opts='{"BUILDKITE_PLUGIN_K8S_MOUNT_HOSTPATH_0": "/host:/mnt", "BUILDKITE_PLUGIN_K8S_MOUNT_EMPTYDIR_0": "/scratch"}'
  expect_eq "hostPath volume" '[{"hostPath":{"path":"/host","type":"DirectoryOrCreate"},"name":"hostpath-0"}]' \
    "$(pod_query "$opts" '[.volumes[] | select(.name == "hostpath-0")]')"
  expect_eq "emptyDir volume" '[{"emptyDir":{},"name":"emptydir-0"}]' \
    "$(pod_query "$opts" "$emptydir_volumes")"
  ((fails == 0))
}

test_automount_true() {
  expect_eq "field" 'true' \
    "$(pod_query '{"BUILDKITE_PLUGIN_K8S_AUTOMOUNT_SERVICE_ACCOUNT_TOKEN": "true"}' '.automountServiceAccountToken')"
  ((fails == 0))
}

test_automount_false() {
  expect_eq "field" 'false' \
    "$(pod_query '{"BUILDKITE_PLUGIN_K8S_AUTOMOUNT_SERVICE_ACCOUNT_TOKEN": "false"}' '.automountServiceAccountToken')"
  ((fails == 0))
}

test_automount_any_case() {
  expect_eq "field" 'false' \
    "$(pod_query '{"BUILDKITE_PLUGIN_K8S_AUTOMOUNT_SERVICE_ACCOUNT_TOKEN": "FALSE"}' '.automountServiceAccountToken')"
  ((fails == 0))
}

test_automount_invalid() {
  local err
  if err="$(render job.jsonnet '{"BUILDKITE_PLUGIN_K8S_AUTOMOUNT_SERVICE_ACCOUNT_TOKEN": "Yes"}' 2>&1)"; then
    printf '    render of "Yes": want a failure, got success\n'
    fails=$((fails + 1))
  fi
  if [[ "$err" != *"got: Yes"* ]]; then
    printf '    error text: want the value as set, "Yes", got %q\n' "$err"
    fails=$((fails + 1))
  fi
  ((fails == 0))
}

test_externalsecret_unchanged() {
  local opts='{"BUILDKITE_PLUGIN_K8S_MOUNT_EMPTYDIR_0": "/a", "BUILDKITE_PLUGIN_K8S_AUTOMOUNT_SERVICE_ACCOUNT_TOKEN": "false"}'
  expect_eq "ExternalSecret" "$(render externalsecret.jsonnet '{}' | jq -cS .)" \
    "$(render externalsecret.jsonnet "$opts" | jq -cS .)"
  ((fails == 0))
}

overall=0

# report <name> <exit code> prints PASS or FAIL for a test.
report() {
  if [[ "$2" == 0 ]]; then
    echo "PASS $1"
  else
    echo "FAIL $1"
    overall=1
  fi
}

(test_no_options)
report test_no_options $?
(test_emptydir_string)
report test_emptydir_string $?
(test_emptydir_array)
report test_emptydir_array $?
(test_emptydir_numeric_order)
report test_emptydir_numeric_order $?
(test_emptydir_empty_entry_dropped)
report test_emptydir_empty_entry_dropped $?
(test_emptydir_other_prefix_ignored)
report test_emptydir_other_prefix_ignored $?
(test_emptydir_keeps_hostpath)
report test_emptydir_keeps_hostpath $?
(test_automount_true)
report test_automount_true $?
(test_automount_false)
report test_automount_false $?
(test_automount_any_case)
report test_automount_any_case $?
(test_automount_invalid)
report test_automount_invalid $?
(test_externalsecret_unchanged)
report test_externalsecret_unchanged $?

exit "$overall"
