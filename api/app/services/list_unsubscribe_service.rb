# Generates List-Unsubscribe and List-Unsubscribe-Post headers per RFC 8058 (spec 18.4.2)
# These headers enable one-click unsubscribe in email clients.
class ListUnsubscribeService
  def initialize(organization, message)
    @organization = organization
    @message = message
  end

  def headers
    token = generate_unsubscribe_token
    unsubscribe_url = "#{base_url}/api/v1/unsubscribe/#{token}"

    {
      "List-Unsubscribe" => "<#{unsubscribe_url}>, <mailto:unsubscribe@#{@organization.default_domain&.name}?subject=unsubscribe>",
      "List-Unsubscribe-Post" => "List-Unsubscribe=One-Click"
    }
  end

  def self.process_unsubscribe(token)
    payload = verifier.verify(token)

    org = Organization.find_by(key: payload["org_key"])
    return nil unless org

    org.mail_filters.find_or_create_by!(
      kind: MailFilter::KIND_BLOCKLIST,
      value: payload["from_address"]
    )

    { organization: org.default_domain&.name, unsubscribed: payload["from_address"] }
  rescue ActiveSupport::MessageVerifier::InvalidSignature
    nil
  end

  def self.verifier
    Rails.application.message_verifier(:unsubscribe)
  end

  private

  def generate_unsubscribe_token
    payload = {
      org_key: @organization.key,
      msg_key: @message.key,
      from_address: @message.to_address
    }
    self.class.verifier.generate(payload, expires_in: 90.days)
  end

  def base_url
    ENV.fetch("APP_URL", "http://localhost:4000")
  end
end
