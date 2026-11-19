# Contributing to inbox2

Thanks for wanting to contribute. PRs are welcome across the whole repo —
clients, server, docs.

## Before you start

- For anything larger than a small fix, open an issue first so we can agree on
  the direction before you invest time.
- Local dev setup, repo layout, and per-component guides live in
  [CLAUDE.md](CLAUDE.md) and [docs/](docs/).

## Ground rules

- **API** (`api/`): every endpoint needs positive + negative specs
  (`bundle exec rspec`). JSON via Alba serializers, never inline `render json:`.
  Org-scoped queries must be tenant-isolated; API-facing IDs are prefixed
  nanoids.
- **Web frontend** (`ui/web/`): CSS Modules only — no Tailwind, no inline
  styles (ESLint enforces this; `yarn lint` must pass). Check the component
  library in `src/components/` before building new UI. Full keyboard
  operability is a hard guarantee.
- **Native clients** (`ui/desktop`, `ui/ios`, `ui/android`, `ui/cli`): the
  shared Rust core (`ui/desktop/core`) is the single sync/write path — clients
  read SQLite directly, write through the core. Don't fork that pattern.
- Commit messages: short summary line, then a bullet list of changes.

## Licensing of contributions

The repo is split-licensed (see [README](README.md#licensing)): Apache-2.0 for
the clients and shared core, FSL-1.1-ALv2 for `api/`, `mta/`, and `deploy/`.

Contributions are accepted under the license of the component they touch
(inbound = outbound). By submitting a PR you agree that your contribution is
licensed under that component's license, including — for FSL-licensed
components — the automatic future Apache-2.0 grant built into the FSL.

## Developer Certificate of Origin (DCO)

Every commit must be signed off, certifying the
[Developer Certificate of Origin](https://developercertificate.org):

```sh
git commit -s
```

This adds a `Signed-off-by: Your Name <you@example.com>` trailer stating you
have the right to submit the work under the project's licenses. PRs with
unsigned commits can't be merged; fix up with
`git rebase --signoff origin/main`.

## Submitting

1. Fork, branch from `main`, keep the diff focused on one change.
2. Make sure the relevant checks pass locally:
   - `cd api && bundle exec rspec`
   - `cd ui/web && yarn lint && yarn test`
   - Rust: `cargo test` in the crate you touched
3. Open the PR with a clear description of what changed and why. Screenshots
   for UI changes are appreciated.
