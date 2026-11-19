# inbox2

Collaborative domain-based team email. All mail for a connected domain lands in a
unified pool; members define filtered views over it. Free, offline-first native
apps for desktop, iOS, Android, and the terminal — plus a cloud-hosted MX
(Cloud MX) for your own domain and team.

- Website: https://inbox2.com
- App: https://mail.inbox2.com
- Docs: [docs/](docs/) — feature spec, architecture, and per-component guides
- Repo layout, tech stack, and local dev setup: [CLAUDE.md](CLAUDE.md)

## Licensing

This repository uses two licenses, split by component:

| Path | License | What it covers |
|------|---------|----------------|
| everything not listed below — `ui/*` (desktop, iOS, Android, web, CLI, and the shared Rust core), `website/`, `docs/` | [Apache-2.0](LICENSE) | The clients and everything a user installs. Fully open source. |
| `api/` | [FSL-1.1-ALv2](api/LICENSE.md) | Rails API (Cloud MX server) |
| `mta/` | [FSL-1.1-ALv2](mta/LICENSE.md) | Go mail transport (MX inbound + SMTP outbound) |
| `deploy/` | [FSL-1.1-ALv2](deploy/LICENSE.md) | Deployment / infrastructure |

In plain terms:

- **The apps are open source** (Apache-2.0). Use, modify, embed, redistribute —
  no strings beyond the standard Apache terms.
- **The server is Fair Source** ([FSL](https://fsl.software)). You can read it,
  modify it, self-host it for your own organization, and consultants can deploy
  and operate it on a customer's behalf. The one thing you can't do is offer it
  to third parties as a competing commercial service (e.g. selling
  inbox2-as-a-service). Each release automatically converts to Apache-2.0 two
  years after publication.

Bundled third-party code and fonts are listed in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md); see also [NOTICE](NOTICE).

"inbox2" is a trade name of Sadiq Beheer B.V.; the name and logo are not
licensed by either license.

## Contributing

We take PRs — see [CONTRIBUTING.md](CONTRIBUTING.md). All contributions require
a [Developer Certificate of Origin](https://developercertificate.org) sign-off
(`git commit -s`).
