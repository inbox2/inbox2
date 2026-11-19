require "rails_helper"

# An org can have multiple role:owner memberships; owner_id is the primary owner.
RSpec.describe "Multi-owner organizations", type: :request do
  let(:owner1) { create(:user, username: "owner_one") }
  let(:owner2) { create(:user, username: "owner_two") }
  let(:org) { create(:organization, owner: owner1) }
  let!(:m1) { create(:membership, user: owner1, organization: org, role: "owner", status: "active") }
  let!(:m2) { create(:membership, user: owner2, organization: org, role: "owner", status: "active") }

  it "lets a second owner perform owner-gated actions (invite an admin)" do
    create(:subscription, organization: org, plan: Plan.max) # lift collaborator cap
    post "/api/v1/members/invite-mx",
      params: { email: "new@x.test", role: "admin", domain_ids: [org.default_domain.key] }, headers: auth_headers(owner2)
    expect(response).to have_http_status(:created)
  end

  it "transfer_ownership sets the primary without demoting the other owner" do
    post "/api/v1/orgs/#{org.key}/transfer-ownership",
      params: { member_id: m2.key }, headers: auth_headers(owner1)
    expect(response).to have_http_status(:ok)
    expect(org.reload.owner).to eq(owner2)
    # both are still owner-role memberships
    expect(org.owner_memberships.count).to eq(2)
  end

  it "reassigns the primary owner when the primary is offboarded (no orphan)" do
    UserOffboarder.new(user: owner1, organizations: [org], acting_user: owner2,
                       data_handling: "archive", alias_handling: "bounce").call
    org.reload
    expect(org.owner).to eq(owner2)            # primary reassigned to remaining owner
    expect(org.memberships.where(user: owner1)).not_to exist
  end

  it "clears owner_id (nullable) when the last owner leaves" do
    m2.destroy! # only owner1 remains as owner
    UserOffboarder.new(user: owner1, organizations: [org], acting_user: nil,
                       data_handling: "archive", alias_handling: "bounce").call
    expect(org.reload.owner_id).to be_nil
  end
end
