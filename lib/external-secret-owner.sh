#!/bin/bash
#
# set_external_secret_owner JOB_NAME makes the Job JOB_NAME the owner of the
# ExternalSecret JOB_NAME in the current namespace.
#
# The command hook calls it after it creates the Job. The function reads the
# Job's UID and patches the ExternalSecret with an ownerReference to the Job.
# When Kubernetes deletes the Job (ttlSecondsAfterFinished, or a manual delete),
# the garbage collector then deletes the ExternalSecret. The Secret that the
# ExternalSecret created has the ExternalSecret as its owner, so the garbage
# collector deletes the Secret too. The pre-exit hook also deletes the
# ExternalSecret. The ownerReference removes the ExternalSecret when the
# pre-exit hook does not run, for example when the agent pod stops first.
#
# The function never fails the step. When it cannot read the UID or patch the
# ExternalSecret, it prints a warning and returns 0.
set_external_secret_owner() {
  local job_name="$1" uid patch

  if ! uid="$(kubectl get job "$job_name" --output=jsonpath='{.metadata.uid}' 2>&1)" || [[ -z $uid ]]; then
    echo "Warning: cannot read the UID of job ${job_name}, so ExternalSecret ${job_name} has no owner: ${uid}" >&2
    return 0
  fi

  patch="{\"metadata\":{\"ownerReferences\":[{\"apiVersion\":\"batch/v1\",\"kind\":\"Job\",\"name\":\"${job_name}\",\"uid\":\"${uid}\",\"blockOwnerDeletion\":false}]}}"
  if ! kubectl patch externalsecrets.external-secrets.io "$job_name" --type=merge --patch "$patch" >/dev/null 2>&1; then
    echo "Warning: cannot set job ${job_name} as the owner of ExternalSecret ${job_name}" >&2
    return 0
  fi
  echo "ExternalSecret ${job_name} is owned by job ${job_name}"
}
