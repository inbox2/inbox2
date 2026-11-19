require "rails_helper"

RSpec.describe Disk::Quota do
  include_context "disk org"

  it "pools 10 GB per active human member" do
    create(:membership, organization: org, status: "invited") # pending invites do not count
    create(:membership, organization: org, member_type: Membership::TYPE_AGENT)
    expect(described_class.new(org).pool_bytes).to eq(30.gigabytes) # owner, member, other
  end

  it "pools 30 GB per member on max" do
    org.subscription.update!(plan: Plan.max)
    expect(described_class.new(org.reload).pool_bytes).to eq(90.gigabytes)
  end

  it "comes with every paid tier, with no flag to set" do
    Plan.max.update_columns(disk: false, disk_gb_per_member: 0) # the retired columns are ignored
    expect(Plan.max.reload).to have_attributes(disk?: true, disk_gb_per_member: 30)
    expect(Plan.paid).to have_attributes(disk?: true, disk_gb_per_member: 10)
    expect(Plan.free).to have_attributes(disk?: false, disk_gb_per_member: 0)
  end

  it "shrinks at once when a member leaves" do
    other.update!(status: "disabled")
    expect(described_class.new(org.reload).pool_bytes).to eq(20.gigabytes)
  end

  it "uses the SaaS override when set" do
    org.update!(disk_quota_override_gb: 500)
    expect(described_class.new(org).pool_bytes).to eq(500.gigabytes)
  end

  it "meters used and reserved against the pool" do
    org.update!(disk_bytes_used: 3.gigabytes, disk_bytes_reserved: 3.gigabytes)
    quota = described_class.new(org)
    expect(quota.available_bytes).to eq(24.gigabytes)
    expect(quota.percent_used).to eq(20.0)
    expect(quota.fits?(24.gigabytes)).to be(true)
    expect(quota.fits?(24.gigabytes + 1)).to be(false)
  end

  it "is zero on a plan without Disk" do
    org.subscription.update!(plan: Plan.free)
    expect(org.disk_enabled?).to be(false)
    expect(described_class.new(org).pool_bytes).to eq(0)
  end
end
