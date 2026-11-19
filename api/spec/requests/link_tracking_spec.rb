require "rails_helper"

# Link tracking (docs/Open-Tracking.md): rewrite on send + the click redirect.
RSpec.describe "Link tracking" do
  let(:org) { create(:organization, with_default_domain: false) }
  let!(:domain) { create(:domain, organization: org, name: "tuli.com", status: "verified", link_tracking_enabled: true) }
  let(:conversation) { create(:conversation, organization: org) }

  def build_message(html)
    create(:message, conversation: conversation, organization: org, is_inbound: false,
                     from_address: "waseem@tuli.com", to_address: "them@else.com",
                     body_plain: "hi", body_html: html)
  end

  it "rewrites <a href> links to the click redirect and stores the destination" do
    msg = build_message(%(<html><body><a href="https://example.com/a?x=1&amp;y=2">A</a> <a href="mailto:x@y.com">mail</a></body></html>))
    mime = OutboundMailPublisher.new(msg).compose_mime

    expect(msg.reload.tracking_token).to be_present
    expect(mime).to include("https://#{Tracking::DEFAULT_HOST}/l/")
    expect(mime).to include("mailto:x@y.com") # non-http link left alone

    link = TrackedLink.find_by(message_tracking_token: msg.tracking_token)
    expect(link.url).to eq("https://example.com/a?x=1&y=2") # HTML-unescaped
  end

  it "reuses one token for a repeated URL (clicks aggregate per unique link)" do
    msg = build_message(%(<a href="https://a.co/x">1</a><a href="https://a.co/x">2</a>))
    OutboundMailPublisher.new(msg).compose_mime
    expect(TrackedLink.where(message_tracking_token: msg.reload.tracking_token).count).to eq(1)
  end

  it "does not rewrite when link tracking is disabled" do
    domain.update!(link_tracking_enabled: false)
    msg = build_message(%(<a href="https://example.com/a">A</a>))
    mime = OutboundMailPublisher.new(msg).compose_mime
    expect(mime).not_to include("/l/")
    expect(TrackedLink.count).to eq(0)
  end

  describe "GET /l/:token" do
    let(:link) { TrackedLink.for(message_tracking_token: "mtok", url: "https://example.com/dest", organization_id: org.id) }

    it "records a click and 302s to the original URL" do
      expect {
        get "/l/#{link.token}"
      }.to change(LinkClick, :count).by(1)

      expect(response).to have_http_status(:found)
      expect(response.headers["Location"]).to eq("https://example.com/dest")
      expect(response.headers["Cache-Control"]).to include("no-store")
      expect(LinkClick.last.organization_id).to eq(org.id)
    end

    it "flags a security-scanner prefetch and excludes it from the real-click count" do
      get "/l/#{link.token}", headers: { "User-Agent" => "Mozilla/5.0 (SafeLinks)" }
      click = LinkClick.last
      expect(click.proxied).to be(true)
      expect(click.proxy_kind).to eq("safelinks")
      expect(link.clicks.real).to be_empty
    end

    it "404s an unknown token (never an open redirect)" do
      get "/l/nope"
      expect(response).to have_http_status(:not_found)
    end
  end

  it "serializes link click stats + history for the reading pane" do
    msg = build_message(%(<a href="https://example.com/a">A</a>))
    OutboundMailPublisher.new(msg).compose_mime
    link = TrackedLink.find_by(message_tracking_token: msg.reload.tracking_token)
    LinkClick.create!(token: link.token, organization_id: org.id, clicked_at: 1.hour.ago, ip: "203.0.113.5")
    LinkClick.create!(token: link.token, organization_id: org.id, clicked_at: 2.hours.ago, proxied: true, proxy_kind: "safelinks")

    h = MessageSerializer.new(msg).to_h
    expect(h["link_stats"][:click_count]).to eq(1)      # scanner excluded
    expect(h["link_stats"][:links_clicked]).to eq(1)
    expect(h["link_stats"][:bot_hits]).to eq(1)
    expect(h["links"].first["url"]).to eq("https://example.com/a")
    expect(h["links"].first["click_count"]).to eq(1)
    expect(h["links"].first["clicks"].size).to eq(2)    # full history includes scanner
  end
end
