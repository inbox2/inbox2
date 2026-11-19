require "rails_helper"

# E1 endpoint coverage for the SendQuota reputation throttle (spec 8.1.2 /
# docs/Mail-Deliverability.md): sends through our own SMTP are capped for
# young orgs and refused with 429 once the budget is spent.
RSpec.describe "outbound send throttling", type: :request do
  let(:owner) { create(:user, username: "throttleowner") }
  let(:org) { create(:organization, owner: owner, domain: "throttle.com") }
  let!(:membership) { create(:membership, user: owner, organization: org, role: "owner", status: "active") }
  let!(:sender_box) { create(:mailbox, membership: membership, domain: org.default_domain, local_part: "user") }
  let(:headers) { auth_headers(owner) }
  let(:conv) { create(:conversation, organization: org) }

  def spend_hourly_budget!
    15.times do
      create(:message, organization: org, conversation: conv,
        is_inbound: false, is_draft: false, to_address: "x@example.com", created_at: 5.minutes.ago)
    end
  end

  it "429s a send once the hourly budget is spent" do
    spend_hourly_budget!
    post "/api/v1/orgs/#{org.key}/messages",
      params: { conversation_id: conv.key, from_address: "user@throttle.com",
                to_address: "c@example.com", body_plain: "hi" },
      headers: headers
    expect(response).to have_http_status(:too_many_requests)
    expect(response.parsed_body["errors"].first["message"]).to include("Hourly sending limit")
  end

  it "429s a message addressed to too many recipients for a new org" do
    to = (1..11).map { |i| "r#{i}@example.com" }.join(", ")
    post "/api/v1/orgs/#{org.key}/messages",
      params: { conversation_id: conv.key, from_address: "user@throttle.com",
                to_address: to, body_plain: "hi" },
      headers: headers
    expect(response).to have_http_status(:too_many_requests)
    expect(response.parsed_body["errors"].first["message"]).to include("at most 10 recipients")
  end

  it "429s scheduling a draft once the budget is spent" do
    draft = create(:message, organization: org, conversation: conv,
      is_inbound: false, is_draft: true, owner_membership_id: membership.id, to_address: "c@example.com")
    spend_hourly_budget!
    post "/api/v1/orgs/#{org.key}/messages/#{draft.key}/schedule",
      params: { send_at: 1.hour.from_now.iso8601 }, headers: headers
    expect(response).to have_http_status(:too_many_requests)
    expect(draft.reload.is_draft).to be(true) # not promoted
  end

  it "does not throttle an org sending through its own ESP (SendGrid)" do
    create(:delivery_channel, organization: org, kind: DeliveryChannel::KIND_SENDGRID,
      name: "SendGrid", is_default: true, status: "active")
    spend_hourly_budget!
    post "/api/v1/orgs/#{org.key}/messages",
      params: { conversation_id: conv.key, from_address: "user@throttle.com",
                to_address: "c@example.com", body_plain: "hi" },
      headers: headers
    expect(response).to have_http_status(:created)
  end

  it "does not throttle a 6-month-old org" do
    org.update!(created_at: 7.months.ago)
    spend_hourly_budget!
    post "/api/v1/orgs/#{org.key}/messages",
      params: { conversation_id: conv.key, from_address: "user@throttle.com",
                to_address: "c@example.com", body_plain: "hi" },
      headers: headers
    expect(response).to have_http_status(:created)
  end
end
