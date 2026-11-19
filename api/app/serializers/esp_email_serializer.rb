class EspEmailSerializer < ApplicationSerializer
  attributes :subject, :tag, :metadata, :size_bytes, :created_at

  attribute(:from) { |m| m.from_address }
  attribute(:to) { |m| MailHeaderEncoding.bare_addresses(m.to_address) }
  attribute(:message_id) { |m| m.message_id_header }

  attribute :deliveries do |m|
    m.deliveries.sort_by(&:id).map { |d| EspDeliverySerializer.new(d).to_h }
  end

  attribute :events, if: proc { params[:events] } do |m|
    m.events.includes(:delivery).order(:id).map { |e| EspEventSerializer.new(e).to_h.except(:email_id) }
  end
end
