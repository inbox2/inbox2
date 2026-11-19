# Helpers for exercising the platform SaaS surface in request specs.
# The real gate is mTLS terminated at the ingress, which stamps the verified
# client cert into ssl-client-* headers. In tests we inject those headers
# directly; the controller only trusts them when SAAS_ALLOW_HEADER_AUTH
# is set, which the :saas around-hook turns on for tagged examples.
module SaasHelpers
  def saas_headers(credential, verify: "SUCCESS", ip: nil)
    headers = {
      "ssl-client-verify" => verify,
      "ssl-client-fingerprint" => credential.cert_fingerprint
    }
    headers["REMOTE_ADDR"] = ip if ip
    headers
  end
end

RSpec.configure do |config|
  config.include SaasHelpers, type: :request

  config.around(:each, :saas) do |example|
    previous = ENV["SAAS_ALLOW_HEADER_AUTH"]
    ENV["SAAS_ALLOW_HEADER_AUTH"] = "1"
    example.run
    ENV["SAAS_ALLOW_HEADER_AUTH"] = previous
  end
end
