require "rails_helper"

# Busy-only upload from devices' local calendars (docs/Calendar.md "External busy").
# E1 mapping: Calendar module — free/busy.
RSpec.describe "External busy", type: :request do
  let(:owner) { create(:user, username: "busyowner", display_name: "Waseem") }
  let(:org) { create(:organization, owner: owner, domain: "busy.test") }
  let!(:membership) { create(:membership, user: owner, organization: org, role: Membership::ROLE_OWNER, status: Membership::STATUS_ACTIVE) }
  let!(:mailbox) { create(:mailbox, membership: membership, domain: org.domains.first, local_part: "waseem") }
  let!(:link) { org.meet_links.create!(membership: membership, label: "Default") }
  let(:headers) { auth_headers(owner) }
  let(:slot_start) { Date.current.next_occurring(:tuesday).in_time_zone("UTC").change(hour: 10) }
  let(:url) { "/api/v1/orgs/#{org.key}/external-busy" }

  def put_busy(source, blocks, as: headers)
    put url, params: { source: source, blocks: blocks }, headers: as, as: :json
  end

  def block(from, to) = { start: from.iso8601, end: to.iso8601 }

  it "makes the meet link read uploaded blocks as busy, bare" do
    put_busy("dev_a", [block(slot_start, slot_start + 1.hour)])
    expect(response).to have_http_status(:no_content)

    get "/api/v1/meet/#{link.token}/availability",
      params: { start: (slot_start - 2.hours).iso8601, end: (slot_start + 4.hours).iso8601 }
    busy = response.parsed_body["busy"]
    expect(busy.size).to eq(1)
    expect(Time.iso8601(busy.first["start"])).to eq(slot_start)
    expect(busy.first.keys).to match_array(%w[start end])
  end

  it "replaces only the uploading device's blocks" do
    put_busy("dev_a", [block(slot_start, slot_start + 1.hour)])
    put_busy("dev_b", [block(slot_start + 2.hours, slot_start + 3.hours)])
    put_busy("dev_a", [])

    expect(ExternalBusyBlock.where(membership: membership).pluck(:source)).to eq(["dev_b"])
  end

  it "drops malformed and out-of-horizon blocks" do
    put_busy("dev_a", [
      block(slot_start + 1.hour, slot_start),           # ends before it starts
      { start: "nope", end: "nope" },
      block(1.year.from_now, 1.year.from_now + 1.hour),  # past the horizon
      block(slot_start, slot_start + 30.minutes)
    ])
    expect(response).to have_http_status(:no_content)
    expect(ExternalBusyBlock.count).to eq(1)
  end

  it "rejects blocks that are not objects" do
    put_busy("dev_a", [nil]) # deep_munge drops the nil: an empty upload, not a 500
    expect(response).to have_http_status(:no_content)
    put_busy("dev_a", ["bad"])
    expect(response).to have_http_status(:unprocessable_content)
    put url, params: { source: "dev_a", blocks: { start: "x" } }, headers: headers, as: :json
    expect(response).to have_http_status(:unprocessable_content)
  end

  it "stops counting a source that went quiet, without a new upload" do
    put_busy("dev_a", [block(slot_start, slot_start + 1.hour)])
    ExternalBusyBlock.update_all(updated_at: (ExternalBusyBlock::STALE_AFTER + 1.day).ago)

    get "/api/v1/meet/#{link.token}/availability",
      params: { start: (slot_start - 2.hours).iso8601, end: (slot_start + 4.hours).iso8601 }
    expect(response.parsed_body["busy"]).to be_empty
  end

  it "rejects a bad source" do
    put_busy("../etc", [])
    expect(response).to have_http_status(:unprocessable_content)
  end

  it "rejects an oversized upload" do
    put_busy("dev_a", Array.new(ExternalBusyBlock::MAX_BLOCKS + 1) { block(slot_start, slot_start + 1.hour) })
    expect(response).to have_http_status(:unprocessable_content)
  end

  it "requires authentication" do
    put url, params: { source: "dev_a", blocks: [] }, as: :json
    expect(response).to have_http_status(:unauthorized)
  end

  it "is tenant-isolated (404 for an org you are not in)" do
    stranger = create(:user, username: "busystranger")
    put_busy("dev_a", [], as: auth_headers(stranger))
    expect(response).to have_http_status(:not_found)
  end
end
