module DeliveryProviders
  # Twilio SendGrid Web API v3 (/mail/send). SendGrid wants structured content
  # rather than raw MIME, so we send From/To/Cc + text+html parts. A 202 means
  # accepted; the message id rides in the X-Message-Id response header.
  class Sendgrid < Base
    ENDPOINT = "https://api.sendgrid.com/v3/mail/send".freeze

    def deliver(context)
      personalization = { to: Array(context.to).map { |a| { email: a } } }
      cc = Array(context.cc).reject(&:blank?)
      personalization[:cc] = cc.map { |a| { email: a } } if cc.any?
      bcc = Array(context.bcc).reject(&:blank?)
      personalization[:bcc] = bcc.map { |a| { email: a } } if bcc.any?

      content = []
      content << { type: "text/plain", value: context.text_body.presence || " " }
      content << { type: "text/html", value: context.html_body } if context.html_body.present?

      body = {
        personalizations: [personalization],
        from: { email: context.from },
        subject: context.subject.presence || "(no subject)",
        content: content
      }

      resp = post_json(ENDPOINT, body: body, headers: { "Authorization" => "Bearer #{cfg(:api_key)}" })
      code = resp.code.to_i

      if code == 202 || code == 200
        Result.ok(resp["X-Message-Id"])
      else
        msg = parse_json(resp)["errors"]&.map { |e| e["message"] }&.join("; ") || resp.body.to_s
        Result.new(accepted: false, error: "SendGrid #{code}: #{msg}", permanent: permanent_status?(code))
      end
    rescue => e
      Result.transient(e.message)
    end

    def verify
      resp = http_get("https://api.sendgrid.com/v3/scopes", headers: { "Authorization" => "Bearer #{cfg(:api_key)}" })
      resp.code.to_i == 200 ? Result.ok : Result.permanent_failure("SendGrid auth failed (#{resp.code})")
    rescue => e
      Result.transient(e.message)
    end
  end
end
