module DeliveryProviders
  # Messy (api.messy.sh) raw send — mirrors MessyClient#send_message but with the
  # org's own per-channel API key. Messy fixes the from-identity on the account
  # the key belongs to, so we pass subject + body + recipients only.
  class Messy < Base
    DEFAULT_BASE_URL = "https://api.messy.sh".freeze

    def deliver(context)
      base = cfg(:base_url) || DEFAULT_BASE_URL
      recipients = (Array(context.to) + Array(context.cc) + Array(context.bcc)).reject(&:blank?)

      message = {
        to: recipients.join(","),
        subject: context.subject.presence || "(no subject)",
        body: context.html_body.presence || context.text_body.to_s
      }

      resp = post_json("#{base}/messages",
        body: { type: "email", message: message },
        headers: { "Authorization" => "Bearer #{cfg(:api_key)}" })
      code = resp.code.to_i

      if code.between?(200, 299)
        Result.ok(parse_json(resp)["id"])
      else
        msg = parse_json(resp).values_at("error", "errors").compact.first || resp.body.to_s
        Result.new(accepted: false, error: "Messy #{code}: #{msg}", permanent: permanent_status?(code))
      end
    rescue => e
      Result.transient(e.message)
    end
  end
end
