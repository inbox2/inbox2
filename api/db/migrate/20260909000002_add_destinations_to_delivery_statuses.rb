# One DeliveryStatus per DESTINATION instead of per message.
#
# A queued job is only safe to retry while it maps to exactly one SMTP envelope:
# `sendEnvelope` fails before DATA, so a failed job means nobody received the
# mail. Deliver to several destinations under one row and a partial success plus
# a whole-job retry mails the successful recipients twice. So the publisher now
# splits by recipient domain (the builtin MTA's unit of delivery — one MX lookup,
# one connection, one envelope) and each destination carries its own row:
#
#   recipients   — the envelope this row owns (comma-joined bare addr-specs)
#   destination  — recipient domain, or "esp:<kind>" for a BYO-ESP channel,
#                  which fans out to every domain itself and so stays one row
#   published_at — set only after the NATS publish (or ESP handoff) succeeded,
#                  so a failed publish stays retryable instead of looking done
class AddDestinationsToDeliveryStatuses < ActiveRecord::Migration[8.1]
  def change
    add_column :delivery_statuses, :recipients, :text, if_not_exists: true
    add_column :delivery_statuses, :destination, :string, if_not_exists: true
    add_column :delivery_statuses, :published_at, :datetime, if_not_exists: true
  end
end
