variable "project_id" {
  description = "GCP project that owns the Gmail OAuth client + Pub/Sub topic"
  type        = string
}

variable "topic_name" {
  description = "Pub/Sub topic name the Gmail watch publishes to"
  type        = string
  default     = "inbox2-gmail-watch"
}

variable "push_endpoint" {
  description = "Rails Gmail webhook URL (the OIDC audience)"
  type        = string
  default     = "https://api.inbox2.com/api/v1/push/gmail"
}

variable "verification_token" {
  description = "Shared secret appended as ?token= to the push endpoint (mirror into GMAIL_PUBSUB_VERIFICATION_TOKEN)"
  type        = string
  sensitive   = true
}
