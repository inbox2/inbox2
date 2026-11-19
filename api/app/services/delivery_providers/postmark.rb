module DeliveryProviders
  # Postmark transactional email API (/email). Structured payload; the server
  # token authenticates and pins the sending server. A 200 with ErrorCode 0 is
  # success — Postmark returns 422 with a non-zero ErrorCode for most rejections.
  class Postmark < Base
    ENDPOINT = "https://api.postmarkapp.com/email".freeze

    def deliver(context)
      body = {
        "From" => context.from,
        "To" => Array(context.to).join(","),
        "Subject" => context.subject.presence || "(no subject)",
        "MessageStream" => cfg(:message_stream) || "outbound"
      }
      cc = Array(context.cc).reject(&:blank?)
      body["Cc"] = cc.join(",") if cc.any?
      bcc = Array(context.bcc).reject(&:blank?)
      body["Bcc"] = bcc.join(",") if bcc.any?
      body["HtmlBody"] = context.html_body if context.html_body.present?
      body["TextBody"] = context.text_body if context.text_body.present?
      body["TextBody"] ||= " " if context.html_body.blank?

      resp = post_json(ENDPOINT, body: body, headers: {
        "Accept" => "application/json",
        "X-Postmark-Server-Token" => cfg(:server_token).to_s
      })
      code = resp.code.to_i
      data = parse_json(resp)

      if code == 200 && data["ErrorCode"].to_i.zero?
        Result.ok(data["MessageID"])
      else
        # Inactive recipient / invalid token / etc. — Postmark error codes above 0
        # are message- or config-specific, not worth backing off on.
        Result.new(accepted: false, error: "Postmark #{data['ErrorCode']}: #{data['Message'] || resp.body}", permanent: true)
      end
    rescue => e
      Result.transient(e.message)
    end

    def verify
      resp = http_get("https://api.postmarkapp.com/server", headers: {
        "Accept" => "application/json",
        "X-Postmark-Server-Token" => cfg(:server_token).to_s
      })
      resp.code.to_i == 200 ? Result.ok : Result.permanent_failure("Postmark auth failed (#{resp.code})")
    rescue => e
      Result.transient(e.message)
    end
  end
end
