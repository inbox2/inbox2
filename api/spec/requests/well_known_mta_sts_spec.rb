require "rails_helper"

# spec 18.3.1 — MTA-STS policy served at mta-sts.<domain>/.well-known/mta-sts.txt
RSpec.describe "GET /.well-known/mta-sts.txt" do
  let(:org) { create(:organization, domain: "acme.com") }

  it "serves the policy text for an enforced domain, resolved from the Host" do
    MtaStsPolicy.create!(domain: org.default_domain, mode: MtaStsPolicy::MODE_ENFORCE, max_age: 86_400, mx_hosts: "mx.inbox2.com")

    host! "mta-sts.acme.com"
    get "/.well-known/mta-sts.txt"

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("text/plain")
    expect(response.body).to include("version: STSv1")
    expect(response.body).to include("mode: enforce")
    expect(response.body).to include("mx: mx.inbox2.com")
  end

  it "404s for a domain with no policy" do
    host! "mta-sts.acme.com"
    get "/.well-known/mta-sts.txt"
    expect(response).to have_http_status(:not_found)
  end

  it "404s when the policy mode is none" do
    MtaStsPolicy.create!(domain: org.default_domain, mode: MtaStsPolicy::MODE_NONE, max_age: 86_400)
    host! "mta-sts.acme.com"
    get "/.well-known/mta-sts.txt"
    expect(response).to have_http_status(:not_found)
  end
end
