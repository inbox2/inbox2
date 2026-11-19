module DeliveryProviders
  # Amazon SES via the SESv2 SendEmail API, handing it our composed raw MIME so
  # SES signs with the customer's own DKIM/verified identity. Credentials come
  # from the channel config (never the host's ambient AWS env).
  class Ses < Base
    def deliver(context)
      require "aws-sdk-sesv2"

      client = Aws::SESV2::Client.new(
        region: cfg(:region) || "us-east-1",
        access_key_id: cfg(:access_key_id),
        secret_access_key: cfg(:secret_access_key)
      )

      resp = client.send_email(
        from_email_address: context.from,
        destination: {
          to_addresses: Array(context.to),
          cc_addresses: Array(context.cc),
          bcc_addresses: Array(context.bcc)
        },
        content: { raw: { data: context.raw_mime } }
      )

      Result.ok(resp.message_id)
    rescue LoadError => e
      Result.permanent_failure("aws-sdk-sesv2 not installed: #{e.message}")
    rescue Aws::SESV2::Errors::ServiceError => e
      # AccountSuspended / unverified identity / bad creds won't fix on retry;
      # throttling and 5xx will.
      permanent = e.code.to_s !~ /Throttl|TooManyRequests|InternalServer/i
      Result.new(accepted: false, error: "#{e.code}: #{e.message}", permanent: permanent)
    rescue => e
      Result.transient(e.message)
    end

    def verify
      require "aws-sdk-sesv2"
      client = Aws::SESV2::Client.new(
        region: cfg(:region) || "us-east-1",
        access_key_id: cfg(:access_key_id),
        secret_access_key: cfg(:secret_access_key)
      )
      client.get_account
      Result.ok
    rescue LoadError => e
      Result.permanent_failure("aws-sdk-sesv2 not installed: #{e.message}")
    rescue Aws::SESV2::Errors::ServiceError => e
      Result.permanent_failure("#{e.code}: #{e.message}")
    rescue => e
      Result.transient(e.message)
    end
  end
end
