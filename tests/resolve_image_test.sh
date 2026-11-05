#!/bin/bash
#
# Tests for lib/resolve-image.sh.
#
# Run: bash tests/resolve_image_test.sh
#
# Each test runs in its own subshell. Most tests put stub timeout, curl,
# kubectl, and buildkite-agent scripts first on PATH. The stubs record their
# arguments and stdin to files in STUB_DIR and print the output that the
# STUB_* variables select. The script prints PASS or FAIL for each test and
# exits 1 when a test fails.

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/lib/resolve-image.sh"

# hex64 <character> prints <character> 64 times.
hex64() {
  local out="" i
  for ((i = 0; i < 64; i++)); do
    out+="$1"
  done
  printf '%s' "$out"
}

# The pull secret holds one Basic credential for three Nexus hosts.
registry_password="s3cret-pass"
auth_value="$(printf '%s' "ci-user:${registry_password}" | base64 | tr -d '\n')"
secret_json="{\"auths\":{\"base-oci.download.greymatter.io\":{\"auth\":\"${auth_value}\"},\"pipeline-oci.download.greymatter.io\":{\"auth\":\"${auth_value}\"},\"download.greymatter.io:8446\":{\"auth\":\"${auth_value}\"}}}"
secret_b64="$(printf '%s' "$secret_json" | base64 | tr -d '\n')"

builder_ref="base-oci.download.greymatter.io/builder:safelogic"
builder_key="k8s-image-digest-a384a041a5e1075f825a4ac41df9ae2d"
proxy_ref="pipeline-oci.download.greymatter.io/proxy-build-ci"
proxy_key="k8s-image-digest-0da8ed72608891926af34e8c6aa66a99"
port_ref="download.greymatter.io:8446/team/app:1.2.3-rc.1"
port_key="k8s-image-digest-e2d29b892d511d4af991f85786e71b97"
digest_1="sha256:$(hex64 1)"
digest_2="sha256:$(hex64 2)"
digest_3="sha256:$(hex64 3)"
ok_response="HTTP/1.1 200 OK\r\nContent-Type: application/vnd.oci.image.index.v1+json\r\nDocker-Content-Digest: ${digest_1}\r\nContent-Length: 1234\r\n\r\n"

fails=0

# expect_eq <description> <want> <got>
expect_eq() {
  if [[ "$2" != "$3" ]]; then
    printf '    %s: want %q, got %q\n' "$1" "$2" "$3"
    fails=$((fails + 1))
  fi
}

# expect_contains <description> <text> <file> checks that <file> contains
# <text> as a substring.
expect_contains() {
  if ! grep -qF -- "$2" "$3" 2>/dev/null; then
    printf '    %s: %q not found in %s\n' "$1" "$2" "${3##*/}"
    fails=$((fails + 1))
  fi
}

# expect_line <description> <line> <file> checks that <file> has a line equal
# to <line>.
expect_line() {
  if ! grep -qxF -- "$2" "$3" 2>/dev/null; then
    printf '    %s: line %q not found in %s\n' "$1" "$2" "${3##*/}"
    fails=$((fails + 1))
  fi
}

# expect_not_contains <description> <text> <file> checks that <file> does not
# contain <text>. A missing file passes.
expect_not_contains() {
  if grep -qF -- "$2" "$3" 2>/dev/null; then
    printf '    %s: %q found in %s\n' "$1" "$2" "${3##*/}"
    fails=$((fails + 1))
  fi
}

# expect_absent <description> <file> checks that a stub did not write <file>.
expect_absent() {
  if [[ -e "$2" ]]; then
    printf '    %s: %s exists\n' "$1" "${2##*/}"
    fails=$((fails + 1))
  fi
}

# line_count <file> prints the number of lines in <file>, or 0 when the file
# does not exist.
line_count() {
  local n=0
  if [[ -e "$1" ]]; then
    while IFS= read -r _; do
      n=$((n + 1))
    done <"$1"
  fi
  printf '%s' "$n"
}

# warning_count <file> prints the number of lines in <file> that start with
# "Warning:".
warning_count() {
  local n=0 line
  if [[ -e "$1" ]]; then
    while IFS= read -r line; do
      if [[ "$line" == Warning:* ]]; then
        n=$((n + 1))
      fi
    done <"$1"
  fi
  printf '%s' "$n"
}

# make_scratch makes STUB_DIR with no stubs. An EXIT trap removes STUB_DIR when
# the test subshell exits.
make_scratch() {
  STUB_DIR="$(mktemp -d)"
  export STUB_DIR
  trap 'rm -rf "${STUB_DIR}"' EXIT
}

# setup_stubs makes STUB_DIR, writes the stubs into STUB_DIR/bin, and puts that
# directory first on PATH.
setup_stubs() {
  make_scratch
  mkdir "${STUB_DIR}/bin"

  cat >"${STUB_DIR}/bin/timeout" <<'EOF'
#!/bin/bash
printf '%s\n' "$1" >>"${STUB_DIR}/timeout.args"
shift
exec "$@"
EOF

  cat >"${STUB_DIR}/bin/curl" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" >>"${STUB_DIR}/curl.args"
cat >>"${STUB_DIR}/curl.stdin"
echo call >>"${STUB_DIR}/curl.calls"
if [[ -n "${STUB_CURL_EXIT:-}" ]]; then
  echo "curl: (${STUB_CURL_EXIT}) stub failure" >&2
  exit "${STUB_CURL_EXIT}"
fi
printf '%b' "${STUB_CURL_RESPONSE:-}"
EOF

  cat >"${STUB_DIR}/bin/kubectl" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" >>"${STUB_DIR}/kubectl.args"
if [[ -n "${STUB_KUBECTL_EXIT:-}" ]]; then
  echo 'Error from server (NotFound): secrets "nexus-agent-pull-secret" not found' >&2
  exit "${STUB_KUBECTL_EXIT}"
fi
printf '%s' "${STUB_KUBECTL_OUTPUT:-}"
EOF

  cat >"${STUB_DIR}/bin/buildkite-agent" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"${STUB_DIR}/buildkite-agent.args"
case "${1:-} ${2:-}" in
  "meta-data exists") exit "${STUB_EXISTS_EXIT:-100}" ;;
  "meta-data get")
    printf '%s' "${STUB_GET_OUTPUT:-}"
    exit "${STUB_GET_EXIT:-0}"
    ;;
  "meta-data set") exit "${STUB_SET_EXIT:-0}" ;;
esac
exit 1
EOF

  chmod +x "${STUB_DIR}"/bin/*
  export PATH="${STUB_DIR}/bin:${PATH}"
  reset_stubs
}

# reset_stubs removes the stub records and sets the default stub behavior: a
# meta-data miss, the pull secret, and a 200 manifest response.
reset_stubs() {
  rm -f "${STUB_DIR}"/*.args "${STUB_DIR}"/*.stdin "${STUB_DIR}"/*.calls "${STUB_DIR}"/*.err
  unset STUB_CURL_EXIT STUB_KUBECTL_EXIT STUB_GET_OUTPUT STUB_GET_EXIT STUB_SET_EXIT
  unset BUILDKITE_PLUGIN_K8S_IMAGE_RESOLVE_TIMEOUT_SEC
  export STUB_EXISTS_EXIT=100
  export STUB_KUBECTL_OUTPUT="$secret_b64"
  export STUB_CURL_RESPONSE="$ok_response"
}

test_nexus_host() {
  local host
  for host in base-oci.download.greymatter.io download.greymatter.io:8446 pipeline-oci.download.greymatter.io \
    a.b.download.greymatter.io; do
    is_nexus_host "$host"
    expect_eq "is_nexus_host ${host}" 0 "$?"
  done
  for host in quay.io download.greymatter.io.evil.com docker.io xdownload.greymatter.io ""; do
    is_nexus_host "$host"
    expect_eq "is_nexus_host ${host}" 1 "$?"
  done
  ((fails == 0))
}

test_split() {
  local out rc
  out="$(split_image_ref "$builder_ref")"
  rc=$?
  expect_eq "rc for ${builder_ref}" 0 "$rc"
  expect_eq "split ${builder_ref}" "base-oci.download.greymatter.io builder safelogic" "$out"

  out="$(split_image_ref "$proxy_ref")"
  expect_eq "split with no tag" "pipeline-oci.download.greymatter.io proxy-build-ci latest" "$out"

  out="$(split_image_ref download.greymatter.io:8446/team/app:1.2)"
  expect_eq "split with a port" "download.greymatter.io:8446 team/app 1.2" "$out"

  out="$(split_image_ref "${builder_ref}@sha256:abc")"
  rc=$?
  expect_eq "rc for a digest reference" 1 "$rc"
  expect_eq "output for a digest reference" "" "$out"

  out="$(split_image_ref builder)"
  rc=$?
  expect_eq "rc for a reference with no host" 1 "$rc"
  ((fails == 0))
}

test_metadata_key() {
  expect_eq "key for ${builder_ref}" "$builder_key" "$(metadata_key_for "$builder_ref")"
  expect_eq "key for ${proxy_ref}" "$proxy_key" "$(metadata_key_for "$proxy_ref")"
  ((fails == 0))
}

# parse_case <description> <want exit code> <want output> <want warning> <response>
# runs parse_manifest_head_digest on <response>, with printf %b escapes, and
# checks the exit code, the output, and the stderr text.
parse_case() {
  local out rc err
  out="$(printf '%b' "$5" | parse_manifest_head_digest "$builder_ref" 2>"${STUB_DIR}/parse.err")"
  rc=$?
  err="$(<"${STUB_DIR}/parse.err")"
  expect_eq "$1: rc" "$2" "$rc"
  expect_eq "$1: output" "$3" "$out"
  expect_eq "$1: stderr" "$4" "$err"
}

test_parse_manifest_head() {
  make_scratch
  local prefix="Warning: step image ${builder_ref}:"

  parse_case "HTTP/2 lowercase with CRLF" 0 "$digest_1" "" \
    "HTTP/2 200\r\ncontent-type: application/vnd.oci.image.index.v1+json\r\ndocker-content-digest: ${digest_1}\r\ncontent-length: 1234\r\n\r\n"
  parse_case "HTTP/1.1 mixed case" 0 "$digest_1" "" "$ok_response"
  parse_case "proxy CONNECT response first" 0 "$digest_2" "" \
    "HTTP/1.1 200 Connection established\r\n\r\nHTTP/2 200\r\ndocker-content-digest: ${digest_2}\r\n\r\n"
  parse_case "two equal digest headers" 0 "$digest_1" "" \
    "HTTP/2 200\r\ndocker-content-digest: ${digest_1}\r\ndocker-content-digest: ${digest_1}\r\n\r\n"
  parse_case "two different digest headers" 1 "" \
    "${prefix} manifest HEAD response has two different Docker-Content-Digest values" \
    "HTTP/2 200\r\ndocker-content-digest: ${digest_1}\r\ndocker-content-digest: ${digest_2}\r\n\r\n"
  parse_case "3xx" 1 "" "${prefix} manifest HEAD returned HTTP 307" \
    "HTTP/1.1 307 Temporary Redirect\r\nLocation: https://example.com/\r\nDocker-Content-Digest: ${digest_1}\r\n\r\n"
  parse_case "200 with no digest" 1 "" "${prefix} manifest HEAD response has no valid Docker-Content-Digest" \
    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n"
  parse_case "uppercase hex digest" 1 "" \
    "${prefix} manifest HEAD response has no valid Docker-Content-Digest: sha256:$(hex64 A)" \
    "HTTP/2 200\r\ndocker-content-digest: sha256:$(hex64 A)\r\n\r\n"
  parse_case "no status line" 1 "" "${prefix} manifest HEAD response has no HTTP status line" ""
  ((fails == 0))
}

test_resolves_and_stores() {
  setup_stubs
  local out rc digest_a

  out="$(resolve_step_image "$builder_ref" 2>"${STUB_DIR}/resolve.err")"
  rc=$?
  expect_eq "rc" 0 "$rc"
  expect_eq "output" "base-oci.download.greymatter.io/builder@${digest_1}" "$out"
  expect_line "meta-data exists" "meta-data exists ${builder_key}" "${STUB_DIR}/buildkite-agent.args"
  expect_line "meta-data set" "meta-data set ${builder_key} ${digest_1}" "${STUB_DIR}/buildkite-agent.args"
  expect_line "HEAD request" "-I" "${STUB_DIR}/curl.args"
  expect_line "time limit" "--max-time" "${STUB_DIR}/curl.args"
  expect_line "time limit value" "10" "${STUB_DIR}/curl.args"
  expect_line "kubectl time limit" "10" "${STUB_DIR}/timeout.args"
  expect_line "config on stdin" "-" "${STUB_DIR}/curl.args"
  expect_line "manifest URL" "https://base-oci.download.greymatter.io/v2/builder/manifests/safelogic" "${STUB_DIR}/curl.args"
  expect_contains "index media type" "application/vnd.oci.image.index.v1+json" "${STUB_DIR}/curl.args"
  expect_contains "Basic credential on stdin" "Authorization: Basic ${auth_value}" "${STUB_DIR}/curl.stdin"
  expect_line "pull secret" "nexus-agent-pull-secret" "${STUB_DIR}/kubectl.args"
  expect_line "resolved log line" "Step image ${builder_ref} resolved to ${digest_1}" "${STUB_DIR}/resolve.err"
  expect_eq "warnings" 0 "$(warning_count "${STUB_DIR}/resolve.err")"
  expect_eq "manifest requests" 1 "$(line_count "${STUB_DIR}/curl.calls")"

  # resolve_step_image accepts an HTTP/2 response with a lowercase header name
  # and an image with no tag.
  reset_stubs
  digest_a="sha256:$(hex64 a)"
  export STUB_CURL_RESPONSE="HTTP/2 200\r\ncontent-type: application/vnd.oci.image.index.v1+json\r\ndocker-content-digest: ${digest_a}\r\n\r\n"
  out="$(resolve_step_image "$proxy_ref" 2>/dev/null)"
  rc=$?
  expect_eq "HTTP/2 rc" 0 "$rc"
  expect_eq "HTTP/2 output" "${proxy_ref}@${digest_a}" "$out"
  expect_line "HTTP/2 manifest URL" "https://pipeline-oci.download.greymatter.io/v2/proxy-build-ci/manifests/latest" "${STUB_DIR}/curl.args"
  expect_line "HTTP/2 meta-data set" "meta-data set ${proxy_key} ${digest_a}" "${STUB_DIR}/buildkite-agent.args"

  # resolve_step_image accepts a host with a port and a tag with "-" and ".".
  reset_stubs
  out="$(resolve_step_image "$port_ref" 2>/dev/null)"
  rc=$?
  expect_eq "port rc" 0 "$rc"
  expect_eq "port output" "download.greymatter.io:8446/team/app@${digest_1}" "$out"
  expect_line "port manifest URL" "https://download.greymatter.io:8446/v2/team/app/manifests/1.2.3-rc.1" "${STUB_DIR}/curl.args"
  expect_line "port meta-data set" "meta-data set ${port_key} ${digest_1}" "${STUB_DIR}/buildkite-agent.args"
  expect_contains "port credential on stdin" "Authorization: Basic ${auth_value}" "${STUB_DIR}/curl.stdin"

  # BUILDKITE_PLUGIN_K8S_IMAGE_RESOLVE_TIMEOUT_SEC sets both time limits.
  reset_stubs
  export BUILDKITE_PLUGIN_K8S_IMAGE_RESOLVE_TIMEOUT_SEC=3
  out="$(resolve_step_image "$builder_ref" 2>/dev/null)"
  expect_eq "custom time limit: output" "base-oci.download.greymatter.io/builder@${digest_1}" "$out"
  expect_line "custom time limit: curl" "3" "${STUB_DIR}/curl.args"
  expect_line "custom time limit: kubectl" "3" "${STUB_DIR}/timeout.args"
  ((fails == 0))
}

test_uses_metadata() {
  setup_stubs
  local out rc
  export STUB_EXISTS_EXIT=0
  export STUB_GET_OUTPUT="$digest_2"

  out="$(resolve_step_image "$builder_ref" 2>"${STUB_DIR}/resolve.err")"
  rc=$?
  expect_eq "rc" 0 "$rc"
  expect_eq "output" "base-oci.download.greymatter.io/builder@${digest_2}" "$out"
  expect_line "meta-data get" "meta-data get ${builder_key}" "${STUB_DIR}/buildkite-agent.args"
  expect_not_contains "meta-data set" "meta-data set" "${STUB_DIR}/buildkite-agent.args"
  expect_absent "curl calls" "${STUB_DIR}/curl.calls"
  expect_absent "kubectl calls" "${STUB_DIR}/kubectl.args"
  expect_absent "timeout calls" "${STUB_DIR}/timeout.args"
  expect_line "meta-data log line" "Step image ${builder_ref} from build meta-data: ${digest_2}" "${STUB_DIR}/resolve.err"
  ((fails == 0))
}

# expect_fallback <description> <cause> [<ref>] checks that resolve_step_image
# prints nothing to stdout, returns 1, and prints exactly one warning line to
# stderr, which is "Warning: step image <ref>: <cause>".
expect_fallback() {
  local ref="${3:-$builder_ref}" out rc
  out="$(resolve_step_image "$ref" 2>"${STUB_DIR}/resolve.err")"
  rc=$?
  expect_eq "$1: rc" 1 "$rc"
  expect_eq "$1: output" "" "$out"
  expect_line "$1: cause line" "Warning: step image ${ref}: $2" "${STUB_DIR}/resolve.err"
  expect_eq "$1: warning lines" 1 "$(warning_count "${STUB_DIR}/resolve.err")"
}

# expect_requests <description> <count> checks the number of manifest requests.
expect_requests() {
  expect_eq "$1: manifest requests" "$2" "$(line_count "${STUB_DIR}/curl.calls")"
}

# expect_metadata <description> <line>... checks that the buildkite-agent stub
# received exactly the given commands, in order.
expect_metadata() {
  local description="$1" want got=""
  shift
  want="$(printf '%s\n' "$@")"
  if [[ -e "${STUB_DIR}/buildkite-agent.args" ]]; then
    got="$(<"${STUB_DIR}/buildkite-agent.args")"
  fi
  expect_eq "${description}: buildkite-agent calls" "${want%$'\n'}" "$got"
}

test_fallback_on_error() {
  setup_stubs
  local got exists_line="meta-data exists ${builder_key}"
  local set_line="meta-data set ${builder_key} ${digest_1}"

  export STUB_CURL_RESPONSE="HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: BASIC realm=Sonatype\r\n\r\n"
  expect_fallback "401" "manifest HEAD returned HTTP 401"
  expect_requests "401" 1
  expect_metadata "401" "$exists_line"

  reset_stubs
  export STUB_CURL_RESPONSE="HTTP/1.1 503 Service Unavailable\r\nDocker-Content-Digest: ${digest_1}\r\n\r\n"
  expect_fallback "503" "manifest HEAD returned HTTP 503"
  expect_requests "503" 1
  expect_metadata "503" "$exists_line"

  reset_stubs
  export STUB_CURL_EXIT=28
  expect_fallback "curl timeout" "manifest HEAD: curl exited 28"
  expect_requests "curl timeout" 1
  expect_metadata "curl timeout" "$exists_line"
  expect_line "curl timeout: curl error line" "curl: (28) stub failure" "${STUB_DIR}/resolve.err"

  reset_stubs
  export STUB_KUBECTL_EXIT=1
  expect_fallback "missing pull secret" "kubectl get secret nexus-agent-pull-secret exited 1"
  expect_requests "missing pull secret" 0
  expect_metadata "missing pull secret" "$exists_line"

  reset_stubs
  export STUB_KUBECTL_OUTPUT
  STUB_KUBECTL_OUTPUT="$(printf '%s' "not json" | base64 | tr -d '\n')"
  expect_fallback "pull secret not JSON" "nexus-agent-pull-secret .dockerconfigjson is not valid JSON"
  expect_requests "pull secret not JSON" 0

  reset_stubs
  expect_fallback "host not in the pull secret" \
    "no credentials for other-oci.download.greymatter.io in nexus-agent-pull-secret" \
    "other-oci.download.greymatter.io/builder:safelogic"
  expect_requests "host not in the pull secret" 0

  reset_stubs
  export STUB_EXISTS_EXIT=1
  expect_fallback "meta-data exists error" "meta-data exists for ${builder_key} exited 1"
  expect_requests "meta-data exists error" 0
  expect_absent "meta-data exists error: kubectl calls" "${STUB_DIR}/kubectl.args"
  expect_metadata "meta-data exists error" "$exists_line"

  reset_stubs
  export STUB_EXISTS_EXIT=0 STUB_GET_EXIT=1
  expect_fallback "meta-data get error" "meta-data get for ${builder_key} exited 1"
  expect_requests "meta-data get error" 0
  expect_metadata "meta-data get error" "$exists_line" "meta-data get ${builder_key}"

  reset_stubs
  export STUB_EXISTS_EXIT=0 STUB_GET_OUTPUT="latest"
  expect_fallback "meta-data value not a digest" "meta-data value for ${builder_key} is not a digest: latest"
  expect_requests "meta-data value not a digest" 0
  expect_metadata "meta-data value not a digest" "$exists_line" "meta-data get ${builder_key}"

  reset_stubs
  export STUB_SET_EXIT=1
  expect_fallback "meta-data set error" "meta-data set for ${builder_key} exited 1"
  expect_requests "meta-data set error" 1
  expect_metadata "meta-data set error" "$exists_line" "$set_line"

  reset_stubs
  export BUILDKITE_PLUGIN_K8S_IMAGE_RESOLVE_TIMEOUT_SEC=abc
  expect_fallback "time limit not an integer" \
    "BUILDKITE_PLUGIN_K8S_IMAGE_RESOLVE_TIMEOUT_SEC is not a positive integer: abc"
  expect_requests "time limit not an integer" 0
  expect_absent "time limit not an integer: kubectl calls" "${STUB_DIR}/kubectl.args"
  expect_metadata "time limit not an integer" "$exists_line"

  reset_stubs
  expect_fallback "digest reference" \
    "the reference has a digest or is not <host>/<repository>[:<tag>]" "${builder_ref}@${digest_1}"
  expect_absent "digest reference: buildkite-agent calls" "${STUB_DIR}/buildkite-agent.args"

  reset_stubs
  expect_fallback "host not on Nexus" "host quay.io is not a Nexus host" "quay.io/greymatter/builder:safelogic"
  expect_absent "host not on Nexus: buildkite-agent calls" "${STUB_DIR}/buildkite-agent.args"
  expect_absent "host not on Nexus: kubectl calls" "${STUB_DIR}/kubectl.args"
  expect_requests "host not on Nexus" 0

  # Under `set -euo pipefail`, apply_step_image_resolution with the real
  # resolve_step_image returns 0 after a failed HEAD request. The caller
  # continues.
  reset_stubs
  export STUB_CURL_RESPONSE="HTTP/1.1 503 Service Unavailable\r\n\r\n"
  got="$(apply_case true "$builder_ref")"
  expect_eq "apply after 503" "${builder_ref}|true|0" "$got"
  expect_requests "apply after 503" 1
  expect_line "apply after 503: cause line" \
    "Warning: step image ${builder_ref}: manifest HEAD returned HTTP 503" "${STUB_DIR}/apply.err"
  expect_line "apply after 503: summary line" \
    "Warning: using the tag because step image resolution failed for ${builder_ref}" "${STUB_DIR}/apply.err"
  expect_eq "apply after 503: stderr lines" 2 "$(line_count "${STUB_DIR}/apply.err")"
  ((fails == 0))
}

test_no_credentials_leak() {
  setup_stubs
  local opts

  (
    set -x
    resolve_step_image "$builder_ref"
  ) >"${STUB_DIR}/resolve.out" 2>"${STUB_DIR}/trace.err"
  expect_contains "xtrace output" "+ split_image_ref ${builder_ref}" "${STUB_DIR}/trace.err"
  expect_contains "resolved output" "@${digest_1}" "${STUB_DIR}/resolve.out"
  expect_contains "credential sent on stdin" "$auth_value" "${STUB_DIR}/curl.stdin"
  expect_not_contains "auth value in xtrace" "$auth_value" "${STUB_DIR}/trace.err"
  expect_not_contains "pull secret in xtrace" "$secret_b64" "${STUB_DIR}/trace.err"
  expect_not_contains "password in xtrace" "$registry_password" "${STUB_DIR}/trace.err"
  expect_not_contains "auth value in curl arguments" "$auth_value" "${STUB_DIR}/curl.args"

  # head_manifest_digest turns xtrace and allexport back on in the calling shell.
  reset_stubs
  opts="$(
    {
      set -x -a
      head_manifest_digest "$builder_ref" base-oci.download.greymatter.io builder safelogic 10 >/dev/null
      printf '%s' "$-"
    } 2>"${STUB_DIR}/head.err"
  )"
  expect_contains "head_manifest_digest ran" "+ head_manifest_digest ${builder_ref}" "${STUB_DIR}/head.err"
  expect_not_contains "auth value in head_manifest_digest xtrace" "$auth_value" "${STUB_DIR}/head.err"
  expect_eq "head_manifest_digest: xtrace on" "x" "$(tr -cd 'x' <<<"$opts")"
  expect_eq "head_manifest_digest: allexport on" "a" "$(tr -cd 'a' <<<"$opts")"

  # read_pull_secret_auth does the same. Its stdout is the credential, so the
  # test sends stdout to a file. An assignment under xtrace prints the value.
  reset_stubs
  opts="$(
    {
      set -x -a
      read_pull_secret_auth "$builder_ref" base-oci.download.greymatter.io 10 >"${STUB_DIR}/auth.out"
      printf '%s' "$-"
    } 2>"${STUB_DIR}/auth.err"
  )"
  expect_contains "read_pull_secret_auth ran" "+ read_pull_secret_auth ${builder_ref}" "${STUB_DIR}/auth.err"
  expect_not_contains "auth value in read_pull_secret_auth xtrace" "$auth_value" "${STUB_DIR}/auth.err"
  expect_eq "read_pull_secret_auth: xtrace on" "x" "$(tr -cd 'x' <<<"$opts")"
  expect_eq "read_pull_secret_auth: allexport on" "a" "$(tr -cd 'a' <<<"$opts")"
  expect_line "read_pull_secret_auth: output" "$auth_value" "${STUB_DIR}/auth.out"
  ((fails == 0))
}

# apply_case <always pull> <image> [<pull secret>] runs
# apply_step_image_resolution under `set -euo pipefail` with the plugin
# variables set to the arguments. The value "<unset>" leaves a variable unset,
# and <pull secret> defaults to "<unset>". It prints the exported image, the
# exported always-pull value, and the exit code, separated by "|".
apply_case() {
  (
    set -euo pipefail
    unset BUILDKITE_PLUGIN_K8S_ALWAYS_PULL BUILDKITE_PLUGIN_K8S_IMAGE BUILDKITE_PLUGIN_K8S_IMAGE_PULL_SECRET
    if [[ "$1" != "<unset>" ]]; then
      export BUILDKITE_PLUGIN_K8S_ALWAYS_PULL="$1"
    fi
    if [[ "$2" != "<unset>" ]]; then
      export BUILDKITE_PLUGIN_K8S_IMAGE="$2"
    fi
    if [[ "${3-<unset>}" != "<unset>" ]]; then
      export BUILDKITE_PLUGIN_K8S_IMAGE_PULL_SECRET="$3"
    fi
    local rc=0
    apply_step_image_resolution 2>"${STUB_DIR}/apply.err" || rc=$?
    printf '%s|%s|%s\n' \
      "$(printenv BUILDKITE_PLUGIN_K8S_IMAGE || echo '<unset>')" \
      "$(printenv BUILDKITE_PLUGIN_K8S_ALWAYS_PULL || echo '<unset>')" \
      "$rc"
  )
}

test_apply_exports() {
  setup_stubs
  local got resolved="base-oci.download.greymatter.io/builder@${digest_3}"

  # Replace resolve_step_image with a stub that records each call.
  resolve_step_image() {
    printf '%s\n' "$1" >>"${STUB_DIR}/resolve.calls"
    if [[ "${STUB_RESOLVE_EXIT:-0}" != 0 ]]; then
      return "$STUB_RESOLVE_EXIT"
    fi
    printf '%s\n' "${STUB_RESOLVE_OUTPUT:-}"
  }
  export STUB_RESOLVE_OUTPUT="$resolved"

  got="$(apply_case true "$builder_ref")"
  expect_eq "always-pull true" "${resolved}|false|0" "$got"
  expect_line "always-pull true: resolve call" "$builder_ref" "${STUB_DIR}/resolve.calls"
  expect_eq "always-pull true: stderr lines" 0 "$(line_count "${STUB_DIR}/apply.err")"

  rm -f "${STUB_DIR}/resolve.calls"
  got="$(apply_case true "$builder_ref" "my-registry-secret")"
  expect_eq "other pull secret" "${resolved}|false|0" "$got"
  expect_line "other pull secret: resolve call" "$builder_ref" "${STUB_DIR}/resolve.calls"

  rm -f "${STUB_DIR}/resolve.calls"
  got="$(apply_case false "$builder_ref")"
  expect_eq "always-pull false" "${builder_ref}|false|0" "$got"
  expect_absent "always-pull false: resolve calls" "${STUB_DIR}/resolve.calls"

  got="$(apply_case "<unset>" "$builder_ref")"
  expect_eq "always-pull unset" "${builder_ref}|<unset>|0" "$got"
  expect_absent "always-pull unset: resolve calls" "${STUB_DIR}/resolve.calls"

  got="$(apply_case true "quay.io/greymatter/builder:safelogic")"
  expect_eq "quay.io image" "quay.io/greymatter/builder:safelogic|true|0" "$got"
  expect_absent "quay.io image: resolve calls" "${STUB_DIR}/resolve.calls"
  expect_eq "quay.io image: stderr lines" 0 "$(line_count "${STUB_DIR}/apply.err")"

  got="$(apply_case true "${builder_ref}@${digest_1}")"
  expect_eq "digest reference" "${builder_ref}@${digest_1}|true|0" "$got"
  expect_absent "digest reference: resolve calls" "${STUB_DIR}/resolve.calls"
  expect_eq "digest reference: stderr lines" 0 "$(line_count "${STUB_DIR}/apply.err")"

  got="$(apply_case true "<unset>")"
  expect_eq "image unset" "<unset>|true|0" "$got"
  expect_absent "image unset: resolve calls" "${STUB_DIR}/resolve.calls"

  got="$(apply_case true "$builder_ref" "")"
  expect_eq "empty pull secret" "${builder_ref}|true|0" "$got"
  expect_absent "empty pull secret: resolve calls" "${STUB_DIR}/resolve.calls"
  expect_eq "empty pull secret: stderr lines" 0 "$(line_count "${STUB_DIR}/apply.err")"

  export STUB_RESOLVE_EXIT=1
  got="$(apply_case true "$builder_ref")"
  expect_eq "resolution failure" "${builder_ref}|true|0" "$got"
  expect_eq "resolution failure: stderr lines" 1 "$(line_count "${STUB_DIR}/apply.err")"
  expect_line "resolution failure: log line" \
    "Warning: using the tag because step image resolution failed for ${builder_ref}" "${STUB_DIR}/apply.err"
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

(test_nexus_host)
report test_nexus_host $?
(test_split)
report test_split $?
(test_metadata_key)
report test_metadata_key $?
(test_parse_manifest_head)
report test_parse_manifest_head $?
(test_resolves_and_stores)
report test_resolves_and_stores $?
(test_uses_metadata)
report test_uses_metadata $?
(test_fallback_on_error)
report test_fallback_on_error $?
(test_no_credentials_leak)
report test_no_credentials_leak $?
(test_apply_exports)
report test_apply_exports $?

exit "$overall"
