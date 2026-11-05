#!/bin/bash
#
# Step image resolution for images on the Nexus registry.
#
# hooks/command sources this file. When a step sets `always-pull: true` and its
# image is on a Nexus host, apply_step_image_resolution replaces the image tag
# with the manifest digest. It also sets always-pull to false. The Job then
# runs the digest reference with imagePullPolicy IfNotPresent. A node that
# already has that digest starts the container without a pull.
#
# The first job in a build that uses an image reference sends one manifest HEAD
# request to Nexus. That job stores the digest in build meta-data. Later jobs in
# the build that use the same reference read the digest from build meta-data.
# On any failure, the step keeps its tag and `always-pull`.
#
# A function that returns 1 for a failure first prints one warning line that
# names the stage and the observed value. The predicates is_nexus_host and
# is_manifest_digest, and the parser split_image_ref, print nothing. Their
# callers print the cause.
#
# hooks/command runs under `set -euo pipefail`. Every external command in this
# file has an explicit failure branch.

# The Kubernetes secret that holds the Nexus registry credentials.
readonly nexus_pull_secret="nexus-agent-pull-secret"

# warn_step_image <ref> <message> prints a warning line for <ref> to stderr.
warn_step_image() {
  echo "Warning: step image $1: $2" >&2
}

# is_nexus_host <host> returns 0 when <host> is download.greymatter.io or a
# subdomain of it. Both forms can end with a port.
is_nexus_host() {
  local pattern='^([a-z0-9-]+\.)*download\.greymatter\.io(:[0-9]+)?$'
  [[ "${1:-}" =~ $pattern ]]
}

# is_manifest_digest <value> returns 0 when <value> is "sha256:" followed by 64
# lowercase hex characters.
is_manifest_digest() {
  local pattern='^sha256:[0-9a-f]{64}$'
  [[ "${1:-}" =~ $pattern ]]
}

# split_image_ref <ref> prints "<host> <repository> <tag>" on one line. A
# reference with no tag gets the tag "latest". It returns 1 for a digest
# reference, a reference with no host, or a reference with characters outside
# the registry grammar.
split_image_ref() {
  local ref="${1:-}" host rest last repo tag
  local host_pattern='^[A-Za-z0-9.-]+(:[0-9]+)?$'
  local repo_pattern='^[a-z0-9][a-z0-9._/-]*$'
  local tag_pattern='^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$'

  if [[ "$ref" == *@* || "$ref" != */* ]]; then
    return 1
  fi
  host="${ref%%/*}"
  rest="${ref#*/}"
  # The tag separator is the last ":" in the last path component. A ":" in
  # the host is a port separator.
  last="${rest##*/}"
  if [[ "$last" == *:* ]]; then
    tag="${last##*:}"
    repo="${rest%:*}"
  else
    tag="latest"
    repo="$rest"
  fi
  if [[ ! "$host" =~ $host_pattern || ! "$repo" =~ $repo_pattern || ! "$tag" =~ $tag_pattern ]]; then
    return 1
  fi
  printf '%s %s %s\n' "$host" "$repo" "$tag"
}

# metadata_key_for <ref> prints the build meta-data key for <ref>:
# "k8s-image-digest-" and the first 32 hex characters of the SHA-256 of <ref>.
metadata_key_for() {
  local ref="${1:-}" sum
  local pattern='^[0-9a-f]{32}$'

  sum="$(printf '%s' "$ref" | sha256sum)" || {
    warn_step_image "$ref" "sha256sum failed"
    return 1
  }
  if [[ ! "${sum:0:32}" =~ $pattern ]]; then
    warn_step_image "$ref" "sha256sum printed no hex digest"
    return 1
  fi
  printf 'k8s-image-digest-%s\n' "${sum:0:32}"
}

# image_resolve_timeout_sec <ref> prints the time limit in seconds for each of
# the two calls that resolve a Nexus step image. The calls are
# `kubectl get secret` and the manifest HEAD request. The value is
# BUILDKITE_PLUGIN_K8S_IMAGE_RESOLVE_TIMEOUT_SEC, or 10 when it is unset or
# empty.
image_resolve_timeout_sec() {
  local value="${BUILDKITE_PLUGIN_K8S_IMAGE_RESOLVE_TIMEOUT_SEC:-10}"
  local pattern='^[1-9][0-9]*$'

  if [[ ! "$value" =~ $pattern ]]; then
    warn_step_image "$1" "BUILDKITE_PLUGIN_K8S_IMAGE_RESOLVE_TIMEOUT_SEC is not a positive integer: ${value}"
    return 1
  fi
  printf '%s\n' "$value"
}

# run_untraced <function> [<argument>...] runs <function> with xtrace and
# allexport off, so a credential in a local variable does not reach the trace
# or the environment. Then it turns each option back on if the option was on,
# and returns the exit code of <function>.
run_untraced() {
  local saved_opts="$-" rc=0
  set +x +a
  "$@" || rc=$?
  if [[ "$saved_opts" == *a* ]]; then
    set -a
  fi
  if [[ "$saved_opts" == *x* ]]; then
    set -x
  fi
  return "$rc"
}

# read_pull_secret_auth <ref> <host> <timeout sec> prints the base64 `auth`
# value for <host> from the Nexus pull secret, or returns 1. The value is the
# Basic credential. <timeout sec> is the time limit for `kubectl get secret`.
# Capture the output only with xtrace off, as head_manifest_digest_untraced
# does. Under xtrace, the assignment line prints the value.
read_pull_secret_auth() {
  run_untraced read_pull_secret_auth_untraced "$@"
}

# read_pull_secret_auth_untraced does the work of read_pull_secret_auth. Call it
# only through run_untraced.
read_pull_secret_auth_untraced() {
  local ref="$1" host="$2" timeout_sec="$3"
  local auth_pattern='^[A-Za-z0-9+/]+=*$'
  local encoded config auth rc=0

  encoded="$(timeout "$timeout_sec" kubectl get secret "$nexus_pull_secret" -o jsonpath='{.data.\.dockerconfigjson}')" || rc=$?
  if ((rc != 0)); then
    warn_step_image "$ref" "kubectl get secret ${nexus_pull_secret} exited ${rc}"
    return 1
  fi
  config="$(base64 -d <<<"$encoded" 2>/dev/null)" || {
    warn_step_image "$ref" "${nexus_pull_secret} .dockerconfigjson is not valid base64"
    return 1
  }
  auth="$(jq -r --arg h "$host" '.auths[$h].auth // empty' <<<"$config" 2>/dev/null)" || {
    warn_step_image "$ref" "${nexus_pull_secret} .dockerconfigjson is not valid JSON"
    return 1
  }
  # The pattern keeps quotes and newlines out of the curl config line.
  if [[ ! "$auth" =~ $auth_pattern ]]; then
    warn_step_image "$ref" "no credentials for ${host} in ${nexus_pull_secret}"
    return 1
  fi
  printf '%s\n' "$auth"
}

# parse_manifest_head_digest <ref> reads `curl -I` output on stdin. It prints
# the Docker-Content-Digest of a 200 response, or returns 1. <ref> labels the
# warning lines.
#
# The function uses only the last response, because curl also prints the
# headers of a proxy CONNECT response. HTTP/2 header names are lowercase.
# HTTP/1.1 header names can use any case.
parse_manifest_head_digest() {
  local ref="$1" line value status="" digest="" conflict=""
  local status_pattern='^HTTP/[0-9.]+ ([0-9]{3})'

  while IFS= read -r line; do
    line="${line%$'\r'}"
    if [[ "$line" =~ $status_pattern ]]; then
      status="${BASH_REMATCH[1]}"
      digest=""
      conflict=""
    elif [[ "${line,,}" == docker-content-digest:* ]]; then
      value="${line#*:}"
      value="${value//[[:space:]]/}"
      if [[ -n "$digest" && "$value" != "$digest" ]]; then
        conflict="$value"
      fi
      digest="$value"
    fi
  done

  if [[ -z "$status" ]]; then
    warn_step_image "$ref" "manifest HEAD response has no HTTP status line"
    return 1
  fi
  if [[ "$status" != "200" ]]; then
    warn_step_image "$ref" "manifest HEAD returned HTTP ${status}"
    return 1
  fi
  if [[ -n "$conflict" ]]; then
    warn_step_image "$ref" "manifest HEAD response has two different Docker-Content-Digest values"
    return 1
  fi
  if ! is_manifest_digest "$digest"; then
    warn_step_image "$ref" "manifest HEAD response has no valid Docker-Content-Digest${digest:+: ${digest}}"
    return 1
  fi
  printf '%s\n' "$digest"
}

# head_manifest_digest <ref> <host> <repository> <tag> <timeout sec> prints the
# manifest digest that the registry returns for <tag>, or returns 1.
# <timeout sec> is the time limit for `kubectl get secret` and for the HEAD
# request.
head_manifest_digest() {
  run_untraced head_manifest_digest_untraced "$@"
}

# head_manifest_digest_untraced does the work of head_manifest_digest. Call it
# only through run_untraced.
#
# The function keeps the credential in local variables and never exports it,
# because hooks/command passes the exported environment to lib/job.jsonnet.
# curl reads the Authorization header from a config on stdin, so the
# credential is not on the curl command line. Nexus returns 401 with a Basic
# challenge to a request with no credential, so the first request carries the
# Basic credential.
head_manifest_digest_untraced() {
  local ref="$1" host="$2" repo="$3" tag="$4" timeout_sec="$5"
  local accept='application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json'
  local auth response rc=0

  auth="$(read_pull_secret_auth "$ref" "$host" "$timeout_sec")" || return 1

  # Without -f, curl exits 0 on an HTTP error. parse_manifest_head_digest
  # checks the status line. With -sS, curl prints its own transport error.
  response="$(curl -sS -I --max-time "$timeout_sec" -K - \
    -H "Accept: ${accept}" \
    "https://${host}/v2/${repo}/manifests/${tag}" \
    <<<"header = \"Authorization: Basic ${auth}\"")" || rc=$?
  if ((rc != 0)); then
    warn_step_image "$ref" "manifest HEAD: curl exited ${rc}"
    return 1
  fi
  parse_manifest_head_digest "$ref" <<<"$response"
}

# resolve_step_image <ref> prints "<host>/<repository>@<digest>" and returns 0,
# or prints nothing to stdout and returns 1.
#
# It reads the digest from build meta-data when an earlier job in the build
# stored it. Otherwise it sends one manifest HEAD request to the registry and stores
# the digest in build meta-data. It makes no kubectl, curl, or buildkite-agent
# call for an image that is not on a Nexus host.
#
# Its stdout carries only the result, because apply_step_image_resolution
# captures stdout. The progress and warning lines go to stderr.
resolve_step_image() {
  local ref="${1:-}" parts host repo tag key digest timeout_sec rc=0

  parts="$(split_image_ref "$ref")" || {
    warn_step_image "$ref" "the reference has a digest or is not <host>/<repository>[:<tag>]"
    return 1
  }
  read -r host repo tag <<<"$parts"
  if ! is_nexus_host "$host"; then
    warn_step_image "$ref" "host ${host} is not a Nexus host"
    return 1
  fi
  key="$(metadata_key_for "$ref")" || return 1

  # `meta-data exists` exits 100 when the key is missing.
  buildkite-agent meta-data exists "$key" || rc=$?
  case "$rc" in
    0)
      digest="$(buildkite-agent meta-data get "$key")" || rc=$?
      if ((rc != 0)); then
        warn_step_image "$ref" "meta-data get for ${key} exited ${rc}"
        return 1
      fi
      if ! is_manifest_digest "$digest"; then
        warn_step_image "$ref" "meta-data value for ${key} is not a digest: ${digest}"
        return 1
      fi
      echo "Step image ${ref} from build meta-data: ${digest}" >&2
      ;;
    100)
      timeout_sec="$(image_resolve_timeout_sec "$ref")" || return 1
      digest="$(head_manifest_digest "$ref" "$host" "$repo" "$tag" "$timeout_sec")" || return 1
      rc=0
      buildkite-agent meta-data set "$key" "$digest" || rc=$?
      if ((rc != 0)); then
        warn_step_image "$ref" "meta-data set for ${key} exited ${rc}"
        return 1
      fi
      echo "Step image ${ref} resolved to ${digest}" >&2
      ;;
    *)
      warn_step_image "$ref" "meta-data exists for ${key} exited ${rc}"
      return 1
      ;;
  esac
  printf '%s/%s@%s\n' "$host" "$repo" "$digest"
}

# apply_step_image_resolution reads BUILDKITE_PLUGIN_K8S_IMAGE,
# BUILDKITE_PLUGIN_K8S_ALWAYS_PULL, and BUILDKITE_PLUGIN_K8S_IMAGE_PULL_SECRET.
# It acts only when `always-pull` is "true", the image is on a Nexus host and
# has no digest, and `image-pull-secret` is not an empty string. Then it
# exports the digest reference as BUILDKITE_PLUGIN_K8S_IMAGE and exports
# BUILDKITE_PLUGIN_K8S_ALWAYS_PULL=false. lib/job.jsonnet maps that value to
# imagePullPolicy IfNotPresent. On a resolution failure, it logs one summary
# line after the cause line and changes nothing. It always returns 0.
apply_step_image_resolution() {
  local image="${BUILDKITE_PLUGIN_K8S_IMAGE:-}" resolved

  if [[ "${BUILDKITE_PLUGIN_K8S_ALWAYS_PULL:-}" != "true" || -z "$image" ]]; then
    return 0
  fi
  # `image-pull-secret: ''` attaches no pull secret to the job pod.
  if [[ -v BUILDKITE_PLUGIN_K8S_IMAGE_PULL_SECRET && -z "$BUILDKITE_PLUGIN_K8S_IMAGE_PULL_SECRET" ]]; then
    return 0
  fi
  # A digest reference or an image on another registry is not a failure, so
  # it gets no warning. resolve_step_image checks the host again after it
  # parses the reference.
  if [[ "$image" == *@* ]] || ! is_nexus_host "${image%%/*}"; then
    return 0
  fi

  if resolved="$(resolve_step_image "$image")" && [[ -n "$resolved" ]]; then
    export BUILDKITE_PLUGIN_K8S_IMAGE="$resolved"
    export BUILDKITE_PLUGIN_K8S_ALWAYS_PULL=false
  else
    echo "Warning: using the tag because step image resolution failed for ${image}" >&2
  fi
  return 0
}
