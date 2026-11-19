module DeliveryProviders
  # Mailgun Messages API. We post the composed raw MIME to /messages.mime so the
  # message keeps our exact headers/parts; Mailgun re-signs with the customer's
  # verified sending domain. HTTP basic auth is ("api", <api_key>).
  class Mailgun < Base
    def deliver(context)
      base = cfg(:region).to_s.downcase == "eu" ? "https://api.eu.mailgun.net" : "https://api.mailgun.net"
      url = "#{base}/v3/#{cfg(:domain)}/messages.mime"

      recipients = (Array(context.to) + Array(context.cc) + Array(context.bcc)).reject(&:blank?)
      form = {
        "to" => recipients.join(","),
        "message" => context.raw_mime
      }

      resp = post_form(url, form: form, basic_auth: ["api", cfg(:api_key).to_s])
      code = resp.code.to_i

      if code == 200
        Result.ok(parse_json(resp)["id"])
      else
        msg = parse_json(resp)["message"] || resp.body.to_s
        Result.new(accepted: false, error: "Mailgun #{code}: #{msg}", permanent: permanent_status?(code))
      end
    rescue => e
      Result.transient(e.message)
    end

    def verify
      base = cfg(:region).to_s.downcase == "eu" ? "https://api.eu.mailgun.net" : "https://api.mailgun.net"
      resp = http_get("#{base}/v3/domains/#{cfg(:domain)}", basic_auth: ["api", cfg(:api_key).to_s])
      resp.code.to_i == 200 ? Result.ok : Result.permanent_failure("Mailgun auth/domain check failed (#{resp.code})")
    rescue => e
      Result.transient(e.message)
    end
  end
end
