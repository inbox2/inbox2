require "rails_helper"

RSpec.describe Mailbox, type: :model do
  let(:org) { create(:organization, with_default_domain: false) }
  let(:domain) { create(:domain, organization: org) }
  let(:membership) { create(:membership, organization: org) }

  it "builds a valid mailbox and forms its address" do
    mbx = create(:mailbox, membership: membership, domain: domain, local_part: "sales")
    expect(mbx).to be_valid
    expect(mbx.email_address).to eq("sales@#{domain.name}")
  end

  it "enforces (domain, local_part) uniqueness" do
    create(:mailbox, membership: membership, domain: domain, local_part: "sales")
    other = create(:membership, organization: org)
    dup = build(:mailbox, membership: other, domain: domain, local_part: "SALES")
    expect(dup).not_to be_valid
  end

  it "rejects a domain owned by a different org" do
    other_domain = create(:domain) # belongs to some other org
    mbx = build(:mailbox, membership: membership, domain: other_domain, local_part: "x")
    expect(mbx).not_to be_valid
    expect(mbx.errors[:domain]).to be_present
  end

  it "validates local_part format" do
    expect(build(:mailbox, membership: membership, domain: domain, local_part: "bad space")).not_to be_valid
  end
end
