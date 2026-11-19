# Security Policy

## Reporting a vulnerability

Mail **security@inbox2.com**. Do not open a public issue for security problems.

Include what you found, where (endpoint, file, or component), and steps to
reproduce. You'll get an acknowledgement within 72 hours and a status update as
we work on a fix. We ask that you give us reasonable time to ship the fix
before disclosing publicly, and we'll credit you in the release notes unless
you prefer otherwise.

## Supported versions

inbox2 is developed on `main` and deployed continuously; fixes land there.
Self-hosters should track `main` (or the latest release, once we cut them).

## Scope

- The application code in this repository (`api/`, `mta/`, `ui/web/`,
  `ui/desktop/`, `ui/cli/`, `ui/admin-cli/`, `ui/ios/`, `ui/android/`,
  `website/`).
- The hosted service at inbox2.com / mail.inbox2.com / api.inbox2.com.

Out of scope: denial of service by volume, reports from automated scanners
without a demonstrated impact, and issues in third-party dependencies with no
exploitable path through inbox2 (report those upstream).

## Automated scanning

Pushleft, which deploys inbox2, scans it every day. The source scan runs Trivy
(dependencies, secrets, misconfiguration), gitleaks, OpenGrep security rules,
Brakeman and an importmap audit over the deployed source; the image scan runs
Trivy over the deployed image, and production is gated on fixable criticals.
Accepted findings are recorded in the repository with a reason: paths in
`.security-scan-ignore`, inline `nosemgrep` comments,
`api/config/brakeman.ignore` and, for image packages with no fix, `.trivyignore`.
