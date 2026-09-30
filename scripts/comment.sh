#!/usr/bin/env bash
# Post the review on the pull request, or update the one posted before.
#
# One comment per pull request, found by a hidden marker, so ten pushes leave
# one up-to-date review rather than ten stale ones. Never fails the job: a
# fork's pull request gets a read-only token, and the review still stands in
# the job summary and the artifact.
set -uo pipefail

marker='<!-- apex-directive-review -->'
body_file="$RUNNER_TEMP/apex-review/comment.md"
{
  echo "$marker"
  echo "### Apex Directive review"
  echo
  echo "**${APEX_RESULT:-no verdict}**"
  echo
  echo "<details><summary>Full review</summary>"
  echo
  # GitHub's comment limit is 65,536 characters; leave room for the rest.
  head -c 60000 "$APEX_REPORT"
  echo
  echo "</details>"
} > "$body_file"

existing="$(gh api --paginate "repos/$APEX_REPO/issues/$APEX_PR/comments" \
  --jq ".[] | select(.body | startswith(\"$marker\")) | .id" 2>/dev/null | tail -1)"

if [ -n "$existing" ]; then
  gh api --method PATCH "repos/$APEX_REPO/issues/comments/$existing" -F "body=@$body_file" >/dev/null \
    || echo "::warning::Could not update the review comment. The review is in the job summary."
else
  gh api --method POST "repos/$APEX_REPO/issues/$APEX_PR/comments" -F "body=@$body_file" >/dev/null \
    || echo "::warning::Could not comment on the pull request (a fork's token is read-only, or pull-requests: write is missing). The review is in the job summary."
fi
exit 0
