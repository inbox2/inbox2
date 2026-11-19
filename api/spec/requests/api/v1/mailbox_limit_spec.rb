require "rails_helper"

# The collaborator cap gates membership invites (Free 0 / Startup 2 / Serial
# unlimited seats beyond the primary owner's; co-owners count); the mailbox cap gates address (Mailbox) creation.
RSpec.describe "Plan limits", type: :request do
  let(:owner) { create(:user) }
  let(:org) { create(:organization, owner: owner) }
  let!(:owner_m) { create(:membership, user: owner, organization: org, role: Membership::ROLE_OWNER, status: Membership::STATUS_ACTIVE) }
  let(:headers) { auth_headers(owner) }

  describe "collaborator cap on invite (spec 13.1.4)" do
    it "403s the first collaborator on Free (0 seats)" do
      post "/api/v1/members/invite-mx", params: { email: "new@person.test", role: "member", domain_ids: [org.default_domain.key] }, headers: headers
      expect(response).to have_http_status(:forbidden)
      expect(JSON.parse(response.body)["errors"].first["message"]).to match(/Upgrade/i)
    end

    it "allows up to 2 collaborators on Startup and blocks the 3rd" do
      create(:subscription, organization: org, plan: Plan.paid)
      create(:membership, organization: org, user: create(:user), role: "member", status: "active") # 1/2
      create(:membership, organization: org, user: create(:user), role: "member", status: "active") # 2/2

      post "/api/v1/members/invite-mx", params: { email: "third@person.test", role: "member", domain_ids: [org.default_domain.key] }, headers: headers
      expect(response).to have_http_status(:forbidden)
    end

    it "counts a co-owner against the cap: only the primary owner's seat is free" do
      post "/api/v1/members/invite-mx", params: { email: "co-owner@person.test", role: "owner", domain_ids: [org.default_domain.key] }, headers: headers
      expect(response).to have_http_status(:forbidden) # Free: 0 seats

      create(:subscription, organization: org, plan: Plan.paid)
      post "/api/v1/members/invite-mx", params: { email: "co-owner@person.test", role: "owner", domain_ids: [org.default_domain.key] }, headers: headers
      expect(response).to have_http_status(:created) # takes one of Startup's 2 seats
    end

    it "allows unlimited collaborators on Serial" do
      create(:subscription, organization: org, plan: Plan.max)
      expect {
        post "/api/v1/members/invite-mx", params: { email: "new@person.test", role: "member", domain_ids: [org.default_domain.key] }, headers: headers
      }.to change { org.memberships.count }.by(1)
      expect(response).to have_http_status(:created)
    end
  end

  describe "mailbox cap on mailbox creation" do
    let(:member) { create(:user) }
    let!(:member_m) { create(:membership, user: member, organization: org, role: "member", status: "active") }

    it "403s once the mailbox limit is reached" do
      org.update!(mailbox_limit: 1)
      domain = org.default_domain

      post "/api/v1/orgs/#{org.key}/mailboxes",
        params: { membership_id: owner_m.key, domain_id: domain.key, local_part: "a" }, headers: headers
      expect(response).to have_http_status(:created)

      post "/api/v1/orgs/#{org.key}/mailboxes",
        params: { membership_id: member_m.key, domain_id: domain.key, local_part: "b" }, headers: headers
      expect(response).to have_http_status(:forbidden)
    end

    it "422s a duplicate local_part on the same domain" do
      org.update!(mailbox_limit: 5) # room under the cap, isolating the uniqueness check
      domain = org.default_domain
      create(:mailbox, membership: owner_m, domain: domain, local_part: "dup")
      post "/api/v1/orgs/#{org.key}/mailboxes",
        params: { membership_id: member_m.key, domain_id: domain.key, local_part: "dup" }, headers: headers
      expect(response).to have_http_status(:unprocessable_content)
    end
  end
end
