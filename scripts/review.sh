#!/usr/bin/env bash
# Run `apex review --ci` on one pull request and record what happened.
#
# This step always exits 0 when it got as far as running the CLI: the exit
# code is handed on as an output, so the artifact and the comment steps still
# run, and the action's last step fails the job with the CLI's own code.
set -euo pipefail

out() { echo "$1=$2" >> "$GITHUB_OUTPUT"; }
trim() { sed -E 's/^[[:space:]]+|[[:space:]]+$//g' <<< "$1"; }
fail() { echo "::error::$1"; out exit-code 1; exit 0; }

[ -n "${APEX_PR:-}" ] || fail "No pull request to review. Run this on a pull_request event, or set pr-number."
[[ "$APEX_PR" =~ ^[0-9]+$ ]] || fail "pr-number must be a number, got '$APEX_PR'."
[[ "$APEX_REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || fail "repository must be owner/name, got '$APEX_REPO'."
[[ "$APEX_CLI_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "cli-version must be a version like 0.1.3, got '$APEX_CLI_VERSION'."

# The CLI runs outside any checkout, so it reads the panel from its user
# config only. A repository's own .apex.toml, when it has one, becomes that
# config: same keys, and the repo's choice wins over the inputs.
work="$RUNNER_TEMP/apex-review"
export XDG_CONFIG_HOME="$work/config"
mkdir -p "$XDG_CONFIG_HOME/apex"
config="$XDG_CONFIG_HOME/apex/config.toml"
cd "$work"

if [ -f "$GITHUB_WORKSPACE/.apex.toml" ] && grep -q '^\[\[seats\]\]' "$GITHUB_WORKSPACE/.apex.toml"; then
  cp "$GITHUB_WORKSPACE/.apex.toml" "$config"
  echo "Panel from .apex.toml"
else
  : > "$config"
  roles=(architect tech_lead security architect tech_lead)
  i=0
  IFS=',' read -ra pairs <<< "$APEX_MODELS"
  for pair in "${pairs[@]}"; do
    pair="$(trim "$pair")"
    [ -z "$pair" ] && continue
    # Checked before it goes into TOML: a quote or newline here would be a
    # second key in the file rather than part of a model name.
    [[ "$pair" =~ ^(anthropic|openai|google|openrouter):[A-Za-z0-9._/-]+$ ]] \
      || fail "models: '$pair' is not provider:model (providers: anthropic, openai, google, openrouter)."
    [ "$i" -lt 5 ] || fail "models: a panel has at most five seats."
    printf '[[seats]]\nrole = "%s"\nprovider = "%s"\nmodel = "%s"\n\n' \
      "${roles[$i]}" "${pair%%:*}" "${pair#*:}" >> "$config"
    i=$((i + 1))
  done
  [ "$i" -ge 2 ] || fail "models: a panel needs at least two seats."
  merge="$(trim "$APEX_MERGE")"
  [[ "$merge" =~ ^(anthropic|openai|google|openrouter):[A-Za-z0-9._/-]+$ ]] \
    || fail "merge-model: '$merge' is not provider:model."
  printf '[merge]\nprovider = "%s"\nmodel = "%s"\n' "${merge%%:*}" "${merge#*:}" >> "$config"
  echo "Panel from the models input"
fi

args=(review --ci --pr "$APEX_PR" --repo "$APEX_REPO" --budget "$APEX_BUDGET" --no-tty)
[ -n "$APEX_FAIL_ON" ] && args+=(--fail-on "$APEX_FAIL_ON")
[ -n "$APEX_TEMPLATE" ] && args+=(--template "$APEX_TEMPLATE")
[ "$APEX_REQUIRE_ALL" = "true" ] && args+=(--require-all-seats)

set +e
npx --yes "@apex-directive/cli@$APEX_CLI_VERSION" "${args[@]}" | tee "$work/ci.txt"
code=${PIPESTATUS[0]}
set -e

out exit-code "$code"
result="$(grep '^result: ' "$work/ci.txt" | tail -1 | sed 's/^result: //' || true)"
out result "$result"
if [ -f "$work/apex-review.md" ]; then
  out report "$work/apex-review.md"
  {
    echo "## Apex Directive review"
    echo
    echo "**${result:-no verdict}**"
    echo
    cat "$work/apex-review.md"
  } >> "$GITHUB_STEP_SUMMARY"
fi
