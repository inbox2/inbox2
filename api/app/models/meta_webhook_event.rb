# Ephemeral buffer of a raw Meta webhook payload — see docs/Cloud-Push.md (Meta).
#
# WhatsApp has no pull API for inbound content, so (unlike Gmail/Office365 cloud push,
# which is a content-free nudge) the relay must convey the payload itself. It stores the
# BYTE-EXACT request body + the X-Hub-Signature-256 header here, fans out a lightweight
# nudge carrying this row's key, and the device fetches + verifies the HMAC against its
# locally-held app_secret before normalizing. The buffer is short-lived (TTL-GC'd) and
# holds no Meta secret.
#
# Deduped by provider_event_id (a hash of the raw body) so Meta's retries don't double-buffer.
class MetaWebhookEvent < ApplicationRecord
  include HasPublicId
  key_prefix "mevt"

  # How long a buffered event is retained (fetch window + multi-device grace).
  TTL = 1.hour

  belongs_to :user

  validates :provider_event_id, presence: true, uniqueness: true
  validates :object, presence: true
  validates :raw_payload, presence: true

  # Not yet acked by a device.
  scope :unconsumed, -> { where(consumed_at: nil) }
  # Past the retention window (consumed or not) — eligible for GC.
  scope :expired, -> { where("received_at < ?", TTL.ago) }
  # Still fetchable by a device (within TTL).
  scope :fresh, -> { where("received_at >= ?", TTL.ago) }
end
