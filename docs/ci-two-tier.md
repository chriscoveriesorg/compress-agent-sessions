# Compress-agent-sessions' proposed quick/full conversion

This is a draft-only source proposal for the fork's single workflow. Keep the
PR draft until independent review and the signed activation gates are ready.
This source does not edit live configuration, cron, capacity or caches, and it
does not post anything upstream.

The fork owns this workflow — `portable-capabilities.yml` was added by the
fork, not inherited from `ariccio/compress-agent-sessions` — so the conversion
stays inside fork-owned CI. Runner labels are unchanged: this is a public
repository and the job stays on GitHub-hosted `ubuntu-latest`.

The caller uses a local byte-exact copy of Cifast's tier action from reviewed
commit `f108f046392578027d957a15175edee3542d34f4`. The required check name
`portable-capabilities` is preserved.

The whole contract is one bounded zsh check — install zsh, `zsh -n` three
scripts, run the mocked capability contract — roughly two minutes on
`ubuntu-latest`, so quick and full run identical steps. There is no honest
smaller subset to invent; the tiers differ only in when they run. Pull
requests run the quick tier; only a canonical `batch/**` push runs full. The
workflow previously also triggered on every `main` push and on
`workflow_dispatch`; both triggers are removed, matching the devkit#148
reference (manual runs are superseded by batch pushes). `timeout-minutes: 10`
is preserved unchanged.

`profiles/compress-agent-sessions-batch.toml` is a concrete proposed
enrollment, not an installed profile. It binds the caller's exact full
job/steps and all local action/setup entrypoints. The coordinator separately
binds the workflow blob, repository/App, first attempt, frozen member heads,
base, tested tip/tree, configuration and source.

Before activation retain independent review and a complete first-attempt
full proof of an exact current-base bootstrap tip.
