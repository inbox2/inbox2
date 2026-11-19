require "rails_helper"

RSpec.describe MobileBadgeRefreshJob do
  it "hands the org to the badge fan-out" do
    org = create(:organization)
    expect(MobilePushSender).to receive(:refresh_badge_for_org).with(org)

    described_class.perform_now(org.id)
  end

  it "no-ops when the org is gone" do
    expect(MobilePushSender).not_to receive(:refresh_badge_for_org)

    described_class.perform_now(-1)
  end
end
