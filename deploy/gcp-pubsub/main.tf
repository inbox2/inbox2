# Gmail cloud-push infrastructure (TODO 45.6, docs/Cloud-Push.md).
#
# The desktop/mobile engines call gmail users.watch pointing at this topic;
# Gmail publishes change signals; the push subscription POSTs them to the Rails
# webhook with (a) the shared ?token= and (b) an OIDC JWT minted for the push
# service account — Rails verifies both (GmailPushVerifier).
#
# Apply is manual (like deploy/dns): terraform init && terraform apply with a
# gitignored terraform.tfvars. After applying, set on the API deployment:
#   GMAIL_PUBSUB_TOPIC              = output topic_name
#   GMAIL_PUBSUB_VERIFICATION_TOKEN = var.verification_token
#   GMAIL_PUBSUB_SERVICE_ACCOUNT    = output push_service_account
#   GMAIL_PUBSUB_AUDIENCE           = var.push_endpoint (optional; defaults to it)

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.8"
    }
  }
}

provider "google" {
  project = var.project_id
}

resource "google_pubsub_topic" "gmail_watch" {
  name = var.topic_name

  # Undelivered signals are worthless after the engines' own catch-up poll.
  message_retention_duration = "3600s"
}

# Gmail's watch publisher — Google-owned SA that needs publish rights on the
# topic (https://developers.google.com/gmail/api/guides/push).
resource "google_pubsub_topic_iam_member" "gmail_publisher" {
  topic  = google_pubsub_topic.gmail_watch.name
  role   = "roles/pubsub.publisher"
  member = "serviceAccount:gmail-api-push@system.gserviceaccount.com"
}

# The identity Pub/Sub asserts in the OIDC token on each webhook POST.
resource "google_service_account" "push" {
  account_id   = "${var.topic_name}-push"
  display_name = "inbox2 Gmail push webhook caller"
}

resource "google_pubsub_subscription" "gmail_push" {
  name  = "${var.topic_name}-push-sub"
  topic = google_pubsub_topic.gmail_watch.id

  # A change signal is a content-free trigger; stale retries are useless.
  message_retention_duration = "3600s"
  ack_deadline_seconds       = 20

  expiration_policy {
    ttl = "" # never expire — the engines renew watches, not the subscription
  }

  retry_policy {
    minimum_backoff = "10s"
    maximum_backoff = "300s"
  }

  push_config {
    push_endpoint = "${var.push_endpoint}?token=${var.verification_token}"

    oidc_token {
      service_account_email = google_service_account.push.email
      audience              = var.push_endpoint
    }
  }
}
