output "topic_name" {
  description = "Set as GMAIL_PUBSUB_TOPIC on the API (projects/<proj>/topics/<name>)"
  value       = google_pubsub_topic.gmail_watch.id
}

output "push_service_account" {
  description = "Set as GMAIL_PUBSUB_SERVICE_ACCOUNT on the API"
  value       = google_service_account.push.email
}
