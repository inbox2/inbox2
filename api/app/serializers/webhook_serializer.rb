class WebhookSerializer < ::ApplicationSerializer
  attributes :url, :enabled, :events, :payload_template, :created_at

  # Never expose the secret in read responses (spec 20.1.6 pattern)
end
