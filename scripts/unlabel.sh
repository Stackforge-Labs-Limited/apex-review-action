#!/usr/bin/env bash
# Take the trigger label off the pull request, so adding it again runs a fresh
# review. Only on a `labeled` event: on any other event there is no label that
# started this run, and removing one would be guessing.
#
# Never fails the job: a fork's token is read-only, and a label left on is an
# inconvenience, not a wrong review.
set -uo pipefail

if [ "${APEX_EVENT_ACTION:-}" != "labeled" ] || [ -z "${APEX_LABEL:-}" ]; then
  exit 0
fi

# A label name can hold spaces and slashes; it is a path segment here.
label="$(printf '%s' "$APEX_LABEL" | jq -sRr @uri)"

gh api --method DELETE "repos/$APEX_REPO/issues/$APEX_PR/labels/$label" >/dev/null 2>&1 \
  || echo "::warning::Could not remove the label (a fork's token is read-only, or pull-requests: write is missing). Remove it by hand to run again."
exit 0
