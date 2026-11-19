# One API send: the message as the application gave it. Each recipient gets its
# own Esp::Delivery; all of them carry the same stored message.
class Esp::Message < ApplicationRecord
  key_prefix "em"

  belongs_to :organization
  belongs_to :esp_key, class_name: "Esp::Key"
  has_many :deliveries, class_name: "Esp::Delivery", foreign_key: :esp_message_id, inverse_of: :message, dependent: :destroy
  has_many :events, class_name: "Esp::Event", foreign_key: :esp_message_id, inverse_of: :message, dependent: :destroy

  # Lists never need the stored message.
  scope :without_body, -> { select(column_names - ["raw_mime"]) }

  def from_domain
    MailHeaderEncoding.bare_addresses(from_address).first.to_s.split("@").last.to_s.downcase
  end
end
