# Apex Directive review

A panel of AI models from different labs reviews every pull request, then
agrees on one ranked list of what to fix. The review is posted on the pull
request, kept up to date on each push, and can fail the build on serious
findings.

It runs [`@apex-directive/cli`](https://www.npmjs.com/package/@apex-directive/cli)
on your own API keys. Calls are billed by the model providers directly, and
nothing is sent to Apex Directive.

## Set up

1. Add your provider keys as repository secrets (Settings → Secrets and
   variables → Actions): `ANTHROPIC_API_KEY`, `OPENAI_API_KEY` and
   `GOOGLE_API_KEY` for the default panel.
2. Add this file as `.github/workflows/apex-review.yml`:

```yaml
name: Apex review
on:
  pull_request:

permissions:
  contents: read
  pull-requests: write   # to post the review as a comment

jobs:
  review:
    runs-on: ubuntu-latest
    steps:
      - uses: Stackforge-Labs-Limited/apex-review-action@v1
        with:
          anthropic-api-key: ${{ secrets.ANTHROPIC_API_KEY }}
          openai-api-key: ${{ secrets.OPENAI_API_KEY }}
          google-api-key: ${{ secrets.GOOGLE_API_KEY }}
```

That's it. The next pull request gets a review.

## Choose the panel

The default panel is Claude Sonnet 5.5, GPT-6.1 Sol and Gemini 3.8 Flash,
merged by Claude Sonnet 5.5. Change it with `models` (two to five `provider:model` pairs)
and `merge-model`:

```yaml
        with:
          models: anthropic:claude-sonnet-5-5, openrouter:deepseek/deepseek-v4-pro
          merge-model: anthropic:claude-sonnet-5-5
          anthropic-api-key: ${{ secrets.ANTHROPIC_API_KEY }}
          openrouter-api-key: ${{ secrets.OPENROUTER_API_KEY }}
```

If the repository has an `.apex.toml` with a panel in it (the file
`apex table add` writes), the action uses that instead, so your terminal and
your CI run the same panel.

## Inputs

| Input | Default | What it does |
| --- | --- | --- |
| `anthropic-api-key`, `openai-api-key`, `google-api-key`, `openrouter-api-key` | | Keys for the providers your panel uses. |
| `models` | `anthropic:claude-sonnet-5-5, openai:gpt-6.1-sol, google:gemini-3.8-flash` | The panel. |
| `merge-model` | `anthropic:claude-sonnet-5-5` | The model that merges the findings. |
| `fail-on` | `high` | Fail the job on an open finding at or above `critical`, `high`, `medium` or `low`. `none` never fails on findings. |
| `budget` | `200k` | Refuse to run, sending nothing, if the input is estimated above this many tokens. |
| `template` | | `code`, `architecture`, `document` or `custom`. |
| `require-all-seats` | `false` | Fail if any seat does not answer. |
| `comment` | `true` | Post the review on the pull request. |
| `pr-number`, `repository` | the triggering pull request | Review a different pull request. |
| `cli-version` | pinned | The CLI version to run. |
| `github-token` | `github.token` | Reads the pull request and posts the comment. |

## Outputs and exit codes

`result` is the verdict line, `report` the path to `apex-review.md` (also
uploaded as the `apex-review` artifact and shown in the job summary), and
`exit-code` is the CLI's:

| Code | Meaning |
| --- | --- |
| 0 | Reviewed, nothing at or above `fail-on` |
| 1 | Usage or config error |
| 2 | `fail-on` tripped |
| 3 | Over `budget`; nothing was sent |
| 4 | A seat did not answer |

## Pull requests from forks

GitHub does not give secrets to workflows run from a fork's pull request, so
the panel has no keys there and the job fails with exit 1. Use
`pull_request`, not `pull_request_target`: the second would run your keys
against code you have not reviewed yet.

## License

MIT. The CLI it runs is under its own license; see its npm page.
