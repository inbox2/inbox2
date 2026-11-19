require "rails_helper"

# Pixel injection on the MX send path + opens serialization/poll.
RSpec.describe "MX open tracking" do
  let(:org) { create(:organization, with_default_domain: false) }
  let!(:domain) { create(:domain, organization: org, name: "tuli.com", status: "verified") }
  let(:conversation) { create(:conversation, organization: org) }

  def build_message
    create(:message, conversation: conversation, organization: org, is_inbound: false,
                     from_address: "waseem@tuli.com", to_address: "them@else.com",
                     body_plain: "hi", body_html: "<html><body><p>hi</p></body></html>")
  end

  context "when the sending domain has open tracking enabled" do
    before { domain.update!(open_tracking_enabled: true) }

    it "injects the pixel into the composed MIME and persists a token" do
      msg = build_message
      mime = OutboundMailPublisher.new(msg).compose_mime

      expect(msg.reload.tracking_token).to be_present
      # Raw MIME is quoted-printable (soft-wraps the token), so match the intact
      # host prefix; the exact-URL/idempotency contract is covered in pixel_spec.
      expect(mime).to include("https://#{Tracking::DEFAULT_HOST}/o/")
    end

    it "uses the verified custom tracking host when set" do
      domain.update!(tracking_domain: "track.tuli.com", tracking_domain_verified_at: Time.current)
      msg = build_message
      mime = OutboundMailPublisher.new(msg).compose_mime

      expect(msg.reload.tracking_token).to be_present
      expect(mime).to include("https://track.tuli.com/o/")
    end
  end

  it "does not inject when open tracking is disabled" do
    msg = build_message
    mime = OutboundMailPublisher.new(msg).compose_mime

    expect(msg.reload.tracking_token).to be_nil
    expect(mime).not_to include("/o/")
  end

  it "serializes real vs proxy opens for the reading pane" do
    domain.update!(open_tracking_enabled: true)
    msg = build_message
    OutboundMailPublisher.new(msg).compose_mime # assigns token
    token = msg.reload.tracking_token

    MessageOpen.create!(token: token, organization_id: org.id, opened_at: 1.hour.ago, ip: "203.0.113.9")
    MessageOpen.create!(token: token, organization_id: org.id, opened_at: 2.hours.ago, proxied: true, proxy_kind: "gmail")

    h = MessageSerializer.new(msg).to_h
    expect(h["tracked"]).to be(true)
    expect(h["open_stats"][:opened]).to be(true)
    expect(h["open_stats"][:open_count]).to eq(1)     # proxy hit excluded
    expect(h["open_stats"][:proxy_hits]).to eq(1)
    expect(h["opens"].size).to eq(2)                  # full history includes proxy
  end
end

RSpec.describe "POST /api/v1/tracking/opens", type: :request do
  it "returns opens grouped by token (unauthenticated poll of a pre-secret token)" do
    a = "a" * Tracking::LEGACY_TOKEN_LENGTH
    MessageOpen.create!(token: a, opened_at: Time.current, ip: "1.2.3.4")
    MessageOpen.create!(token: "b" * Tracking::LEGACY_TOKEN_LENGTH, opened_at: Time.current)

    post "/api/v1/tracking/opens", params: { tokens: [a, "n" * Tracking::LEGACY_TOKEN_LENGTH] }, as: :json

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body["opens"].keys).to eq([a])
    expect(body["opens"][a].first["ip"]).to eq("1.2.3.4")
  end
end
