# deploy/

Production runs on Pushleft. Every push to `main` deploys it from GitHub Actions
(`.github/workflows/deploy.yml` → `pl up --production`). The full story is in
[docs/Deployment.md](../docs/Deployment.md).

```
deploy/
  pushleft/     — the one image (Dockerfile) every role in .pl.yaml runs, and
                  `run`, which maps Pushleft's variables onto inbox2's names
  gcp-pubsub/   — Terraform for the Gmail Pub/Sub topic that cloud push uses
                  (docs/Cloud-Push.md)
```

Licensed FSL-1.1-ALv2 (see [LICENSE.md](LICENSE.md)).
