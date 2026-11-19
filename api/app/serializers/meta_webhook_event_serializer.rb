class MetaWebhookEventSerializer < ::ApplicationSerializer
  # The device needs the byte-exact raw body + the signature header to verify the HMAC
  # locally. provider_event_id lets the device dedup; object selects the normalizer.
  attributes :object, :provider_event_id, :raw_payload, :signature_header, :received_at
end
