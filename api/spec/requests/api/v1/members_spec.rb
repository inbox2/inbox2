require "rails_helper"

RSpec.describe "Api::V1::Members", type: :request do
  let(:owner) { create(:user, username: "orgowner") }
  let(:org) { create(:organization, owner: owner, domain: "team.com") }
  let!(:owner_membership) { create(:membership, user: owner, organization: org, role: "owner", status: "active") }
  let(:headers) { auth_headers(owner) }

  # --- Spec 5.1.3, A4.1 — List members ---
  describe "GET /api/v1/orgs/:org_id/members" do
    context "positive" do
      it "lists all members in the organization" do
        member_user = create(:user, username: "member1")
        create(:membership, user: member_user, organization: org, role: "member", status: "active")

        get "/api/v1/orgs/#{org.key}/members", headers: headers
        expect(response).to have_http_status(:ok)
        body = response.parsed_body
        expect(body["members"].length).to eq(2)
        # E5: public IDs only
        body["members"].each do |m|
          expect(m["id"]).to start_with("mbr_")
          expect(m).not_to have_key("internal_id")
          expect(m["user"]["id"]).to start_with("usr_")
        end
      end

      it "includes user details, role, and status" do
        get "/api/v1/orgs/#{org.key}/members", headers: headers
        body = response.parsed_body
        member = body["members"].first
        expect(member).to have_key("role")
        expect(member).to have_key("status")
        expect(member["user"]).to have_key("username")
      end
    end

    context "negative — tenant isolation (E3)" do
      it "returns 404 for an organization the user is not a member of" do
        other_user = create(:user, username: "stranger")
        other_org = create(:organization, owner: other_user, domain: "other.com")
        create(:membership, user: other_user, organization: other_org, role: "owner", status: "active")

        get "/api/v1/orgs/#{other_org.key}/members", headers: headers
        expect(response).to have_http_status(:not_found)
      end
    end

    context "negative — unauthorized" do
      it "rejects unauthenticated request" do
        get "/api/v1/orgs/#{org.key}/members"
        expect(response).to have_http_status(:unauthorized)
      end
    end
  end

  # --- Spec 5.1.1, A4.2 — Invite member (via /members/invite-mx; the org-scoped
  # invite endpoint was removed — nothing called it) ---
  describe "POST /api/v1/members/invite-mx" do
    context "positive" do
      before do
        # Simulate paid plan — free plan blocks all additional collaborators (spec 13.1.4)
        create(:subscription, organization: org, plan: Plan.max)
      end

      it "invites a new member by email" do
        expect {
          post "/api/v1/members/invite-mx",
               params: { email: "newguy@external.com", role: "member", domain_ids: [org.default_domain.key] },
               headers: headers
        }.to change(Membership, :count).by(1)

        expect(response).to have_http_status(:created)
        invite = response.parsed_body["invites"].first
        expect(invite["id"]).to start_with("mbr_")
        expect(invite["role"]).to eq("member")
        expect(invite["status"]).to eq("invited")
      end

      it "defaults role to member when not specified" do
        post "/api/v1/members/invite-mx",
             params: { email: "default@external.com", domain_ids: [org.default_domain.key] },
             headers: headers
        expect(response).to have_http_status(:created)
        expect(response.parsed_body["invites"].first["role"]).to eq("member")
      end

      it "allows admin to invite" do
        admin = create(:user, username: "admin1")
        create(:membership, user: admin, organization: org, role: "admin", status: "active")
        admin_headers = auth_headers(admin)

        post "/api/v1/members/invite-mx",
             params: { email: "from_admin@external.com", domain_ids: [org.default_domain.key] },
             headers: admin_headers
        expect(response).to have_http_status(:created)
      end

      it "reuses existing user if billing_email matches" do
        existing_user = create(:user, username: "existing", billing_email: "shared@external.com")

        post "/api/v1/members/invite-mx",
             params: { email: "shared@external.com", domain_ids: [org.default_domain.key] },
             headers: headers
        expect(response).to have_http_status(:created)
        membership = Membership.last
        expect(membership.user).to eq(existing_user)
      end
    end

    context "negative — role check" do
      it "forbids regular members from inviting" do
        member_user = create(:user, username: "normie")
        create(:membership, user: member_user, organization: org, role: "member", status: "active")
        member_headers = auth_headers(member_user)

        post "/api/v1/members/invite-mx",
             params: { email: "blocked@external.com", domain_ids: [org.default_domain.key] },
             headers: member_headers
        expect(response).to have_http_status(:forbidden)
      end
    end

    context "negative — free plan limit (spec 13.1.4)" do
      it "blocks 2nd collaborator on free plan" do
        # Owner membership already counts as 1 active member
        post "/api/v1/members/invite-mx",
             params: { email: "second@external.com", domain_ids: [org.default_domain.key] },
             headers: headers
        expect(response).to have_http_status(:forbidden)
        expect(response.parsed_body["errors"].first["message"]).to match(/upgrade/i)
      end

      it "blocks a second owner on free plan too (only the primary owner is free)" do
        post "/api/v1/members/invite-mx",
             params: { email: "coowner@external.com", role: "owner", domain_ids: [org.default_domain.key] },
             headers: headers
        expect(response).to have_http_status(:forbidden)
        expect(response.parsed_body["errors"].first["message"]).to match(/upgrade/i)
      end
    end

    context "negative — tenant isolation (E3)" do
      it "rejects inviting to an org the user cannot access" do
        other_user = create(:user, username: "outsider")
        other_org = create(:organization, owner: other_user, domain: "private.com")
        create(:membership, user: other_user, organization: other_org, role: "owner", status: "active")

        post "/api/v1/members/invite-mx",
             params: { email: "test@external.com", domain_ids: [other_org.default_domain.key] },
             headers: headers
        expect(response).to have_http_status(:forbidden)
      end
    end

    # --- Grant ceiling (5.1.5): admins grant member only; owners grant admin/owner ---
    context "negative — grant ceiling" do
      # Take the free-plan collaborator cap out of the picture so a 403 here can
      # only come from the role ceiling, not the upgrade gate.
      before do
        create(:subscription, organization: org, plan: Plan.max)
      end

      let(:admin_user) { create(:user, username: "admin_inv") }
      let!(:admin_membership) { create(:membership, user: admin_user, organization: org, role: "admin", status: "active") }
      let(:admin_headers) { auth_headers(admin_user) }

      it "forbids an admin from inviting someone as admin" do
        post "/api/v1/members/invite-mx",
             params: { email: "newadmin@external.com", role: "admin", domain_ids: [org.default_domain.key] }, headers: admin_headers
        expect(response).to have_http_status(:forbidden)
      end

      it "forbids an admin from inviting someone as owner" do
        post "/api/v1/members/invite-mx",
             params: { email: "newowner@external.com", role: "owner", domain_ids: [org.default_domain.key] }, headers: admin_headers
        expect(response).to have_http_status(:forbidden)
      end

      it "allows the owner to invite an admin" do
        post "/api/v1/members/invite-mx",
             params: { email: "ownersadmin@external.com", role: "admin", domain_ids: [org.default_domain.key] }, headers: headers
        expect(response).to have_http_status(:created)
        expect(response.parsed_body["invites"].first["role"]).to eq("admin")
      end
    end
  end

  # --- Spec 5.1.1, A4.3 — Accept invite ---
  describe "POST /api/v1/members/accept-invite" do
    let(:invited_user) { create(:user, username: "invited_abc123", password: "temporary") }
    let!(:invite_membership) { create(:membership, user: invited_user, organization: org, role: "member", status: "invited") }
    let!(:invite_token) { invite_membership.mint_invite_token! }

    context "positive" do
      it "accepts the invite and activates the membership" do
        post "/api/v1/members/accept-invite", params: {
          invite_id: invite_token,
          username: "realmember",
          password: "newpassword123"
        }
        expect(response).to have_http_status(:ok)
        body = response.parsed_body
        expect(body["user"]["username"]).to eq("realmember")
        expect(body["token"]).to be_present
        expect(invite_membership.reload.status).to eq("active")
        expect(invite_membership.invite_token_digest).to be_nil
      end
    end

    context "negative" do
      it "does not accept the membership key as an invite credential (every teammate can read it)" do
        post "/api/v1/members/accept-invite", params: {
          invite_id: invite_membership.key,
          username: "squatter",
          password: "password123"
        }
        expect(response).to have_http_status(:not_found)
        expect(invite_membership.reload.status).to eq("invited")
        expect(invited_user.reload.username).to eq("invited_abc123")
      end

      it "rejects invalid invite ID" do
        post "/api/v1/members/accept-invite", params: {
          invite_id: "mbr_nonexistent",
          username: "someone",
          password: "password123"
        }
        expect(response).to have_http_status(:not_found)
      end

      it "rejects already-accepted invite" do
        invite_membership.update!(status: "active")
        post "/api/v1/members/accept-invite", params: {
          invite_id: invite_token,
          username: "latecomer",
          password: "password123"
        }
        expect(response).to have_http_status(:not_found)
      end

      it "rejects invalid username" do
        post "/api/v1/members/accept-invite", params: {
          invite_id: invite_token,
          username: "ab",
          password: "password123"
        }
        expect(response).to have_http_status(:unprocessable_content)
      end
    end
  end

  # --- Spec 5.1.5, 5.1.4, A4.4 — Update member ---
  # --- Resend a pending invite ---
  describe "POST /api/v1/orgs/:org_id/members/:id/resend-invite" do
    let(:invitee) { create(:user, username: "pending1", billing_email: "pending1@external.com") }
    let!(:invited) { create(:membership, user: invitee, organization: org, role: "member", status: "invited") }

    it "re-sends the invite email for a pending member" do
      expect {
        post "/api/v1/orgs/#{org.key}/members/#{invited.key}/resend-invite", headers: headers, as: :json
      }.to have_enqueued_job(MessyTriggerJob).with("send_message", hash_including(to: "pending1@external.com"))
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["member"]["status"]).to eq("invited")
    end

    it "returns 404 for a member who already accepted" do
      invited.update!(status: "active")
      post "/api/v1/orgs/#{org.key}/members/#{invited.key}/resend-invite", headers: headers, as: :json
      expect(response).to have_http_status(:not_found)
    end

    it "forbids regular members from resending" do
      member_user = create(:user, username: "plainmember")
      create(:membership, user: member_user, organization: org, role: "member", status: "active")
      post "/api/v1/orgs/#{org.key}/members/#{invited.key}/resend-invite", headers: auth_headers(member_user), as: :json
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "PATCH /api/v1/orgs/:org_id/members/:id" do
    let(:member_user) { create(:user, username: "updatable") }
    let!(:member_membership) { create(:membership, user: member_user, organization: org, role: "member", status: "active") }

    context "positive" do
      it "updates a member's role" do
        patch "/api/v1/orgs/#{org.key}/members/#{member_membership.key}",
              params: { role: "admin" },
              headers: headers
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["member"]["role"]).to eq("admin")
      end

      it "disables a member" do
        patch "/api/v1/orgs/#{org.key}/members/#{member_membership.key}",
              params: { status: "disabled" },
              headers: headers
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["member"]["status"]).to eq("disabled")
      end

      it "refuses to re-enable a member when the plan has no free seat" do
        member_membership.update!(status: "disabled") # Free plan: 0 seats
        patch "/api/v1/orgs/#{org.key}/members/#{member_membership.key}",
              params: { status: "active" },
              headers: headers
        expect(response).to have_http_status(:forbidden)
        expect(member_membership.reload.status).to eq("disabled")
      end

      it "allows an admin to manage a member (e.g. disable) within the member role" do
        admin = create(:user, username: "admin2")
        create(:membership, user: admin, organization: org, role: "admin", status: "active")
        admin_headers = auth_headers(admin)

        patch "/api/v1/orgs/#{org.key}/members/#{member_membership.key}",
              params: { status: "disabled" },
              headers: admin_headers
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["member"]["status"]).to eq("disabled")
      end
    end

    # --- Grant ceiling (5.1.5): admins grant member only; owners grant admin/owner ---
    context "negative — grant ceiling" do
      let(:admin_user) { create(:user, username: "admin_ceiling") }
      let!(:admin_membership) { create(:membership, user: admin_user, organization: org, role: "admin", status: "active") }
      let(:admin_headers) { auth_headers(admin_user) }

      it "forbids an admin from promoting a member to admin" do
        patch "/api/v1/orgs/#{org.key}/members/#{member_membership.key}",
              params: { role: "admin" }, headers: admin_headers
        expect(response).to have_http_status(:forbidden)
        expect(member_membership.reload.role).to eq("member")
      end

      it "forbids an admin from modifying another admin" do
        peer = create(:user, username: "peer_admin")
        peer_membership = create(:membership, user: peer, organization: org, role: "admin", status: "active")

        patch "/api/v1/orgs/#{org.key}/members/#{peer_membership.key}",
              params: { status: "disabled" }, headers: admin_headers
        expect(response).to have_http_status(:forbidden)
      end

      it "allows the owner to promote a member to admin" do
        patch "/api/v1/orgs/#{org.key}/members/#{member_membership.key}",
              params: { role: "admin" }, headers: headers
        expect(response).to have_http_status(:ok)
        expect(member_membership.reload.role).to eq("admin")
      end
    end

    context "negative — self-role change" do
      it "prevents changing own role" do
        patch "/api/v1/orgs/#{org.key}/members/#{owner_membership.key}",
              params: { role: "member" },
              headers: headers
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body["errors"].first["message"]).to match(/own role/i)
      end
    end

    context "negative — role check" do
      it "forbids regular members from updating others" do
        another = create(:user, username: "another")
        another_membership = create(:membership, user: another, organization: org, role: "member", status: "active")
        member_headers = auth_headers(member_user)

        patch "/api/v1/orgs/#{org.key}/members/#{another_membership.key}",
              params: { role: "admin" },
              headers: member_headers
        expect(response).to have_http_status(:forbidden)
      end
    end

    context "negative — tenant isolation (E3)" do
      it "returns 404 for a member in a different org" do
        other_user = create(:user, username: "otherorg")
        other_org = create(:organization, owner: other_user, domain: "else.com")
        other_membership = create(:membership, user: other_user, organization: other_org, role: "owner", status: "active")

        patch "/api/v1/orgs/#{org.key}/members/#{other_membership.key}",
              params: { role: "admin" },
              headers: headers
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  # --- Spec 5.1.4, A4.5 — Remove member ---
  describe "DELETE /api/v1/orgs/:org_id/members/:id" do
    let(:member_user) { create(:user, username: "removable") }
    let!(:member_membership) { create(:membership, user: member_user, organization: org, role: "member", status: "active") }

    context "positive" do
      it "removes the member" do
        expect {
          delete "/api/v1/orgs/#{org.key}/members/#{member_membership.key}", headers: headers
        }.to change(Membership, :count).by(-1)
        expect(response).to have_http_status(:no_content)
      end
    end

    context "negative — self-removal" do
      it "prevents removing yourself" do
        delete "/api/v1/orgs/#{org.key}/members/#{owner_membership.key}", headers: headers
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body["errors"].first["message"]).to match(/yourself/i)
      end
    end

    context "negative — role check" do
      it "forbids regular members from removing others" do
        another = create(:user, username: "safe")
        create(:membership, user: another, organization: org, role: "member", status: "active")
        member_headers = auth_headers(member_user)

        delete "/api/v1/orgs/#{org.key}/members/#{another.memberships.first.key}",
               headers: member_headers
        expect(response).to have_http_status(:forbidden)
      end
    end

    context "negative — tenant isolation (E3)" do
      it "returns 404 for a member in a different org" do
        other_user = create(:user, username: "isolated")
        other_org = create(:organization, owner: other_user, domain: "secret.com")
        other_membership = create(:membership, user: other_user, organization: other_org, role: "owner", status: "active")

        delete "/api/v1/orgs/#{org.key}/members/#{other_membership.key}", headers: headers
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  # --- Spec 5.1.2 — Unlimited members enforcement ---
  describe "unlimited members (spec 5.1.2)" do
    before do
      create(:subscription, organization: org, plan: Plan.max)
    end

    it "allows inviting multiple members on a paid plan without per-seat gating" do
      3.times do |i|
        post "/api/v1/members/invite-mx",
             params: { email: "member#{i}@external.com", domain_ids: [org.default_domain.key] },
             headers: headers
        expect(response).to have_http_status(:created)
      end
      expect(org.memberships.count).to eq(4) # owner + 3 invited
    end
  end

  # --- Status transition restriction ---
  describe "status transition guard" do
    let(:member_user) { create(:user, username: "statusguard") }
    let!(:member_membership) { create(:membership, user: member_user, organization: org, role: "member", status: "active") }

    it "prevents setting status back to invited" do
      patch "/api/v1/orgs/#{org.key}/members/#{member_membership.key}",
            params: { status: "invited" },
            headers: headers
      expect(response).to have_http_status(:ok)
      # Status should not change to invited
      expect(member_membership.reload.status).to eq("active")
    end
  end

  # --- members#accept_invite — accept an org invitation (no auth) ---
  describe "POST /api/v1/members/accept-invite" do
    let(:invited_user) { create(:user, username: "invitee_tmp") }
    let!(:invited_membership) do
      create(:membership, user: invited_user, organization: org,
                          role: Membership::ROLE_MEMBER, status: Membership::STATUS_INVITED)
    end
    let!(:invite_token) { invited_membership.mint_invite_token! }

    context "positive" do
      it "activates the membership and returns a session token" do
        post "/api/v1/members/accept-invite",
             params: { invite_id: invite_token, username: "new_invitee", password: "secret123" }
        expect(response).to have_http_status(:ok)
        body = response.parsed_body
        expect(body["token"]).to be_present
        expect(body["user"]["username"]).to eq("new_invitee")
        expect(invited_membership.reload.status).to eq(Membership::STATUS_ACTIVE)
      end
    end

    context "negative" do
      it "returns 404 for an unknown invite id" do
        post "/api/v1/members/accept-invite",
             params: { invite_id: "mbr_missing", username: "someuser", password: "secret123" }
        expect(response).to have_http_status(:not_found)
      end

      it "returns 404 when the membership is no longer in the invited state" do
        invited_membership.update!(status: Membership::STATUS_ACTIVE)
        post "/api/v1/members/accept-invite",
             params: { invite_id: invite_token, username: "someuser", password: "secret123" }
        expect(response).to have_http_status(:not_found)
      end

      it "returns 422 for an invalid username" do
        post "/api/v1/members/accept-invite",
             params: { invite_id: invite_token, username: "ab", password: "secret123" }
        expect(response).to have_http_status(:unprocessable_content)
      end
    end

    context "security — invite cannot overwrite an existing account's credentials" do
      it "refuses to reset credentials of a claimed account via the invite key" do
        # A real, claimed account (has logged in) gets invited to this org.
        victim = create(:user, username: "victim", password: "victimpass123")
        victim.sessions.create!(last_active_at: Time.current)
        victim_invite = create(:membership, user: victim, organization: org,
                                            role: Membership::ROLE_MEMBER, status: Membership::STATUS_INVITED)
        token = victim_invite.mint_invite_token!

        post "/api/v1/members/accept-invite",
             params: { invite_id: token, username: "pwned", password: "attackerpass" }

        expect(response).to have_http_status(:unauthorized)
        expect(victim.reload.username).to eq("victim")
        expect(victim.authenticate("victimpass123")).to be_truthy
        expect(victim_invite.reload.status).to eq(Membership::STATUS_INVITED)
      end

      it "lets the authenticated owner of a claimed account accept the invite" do
        victim = create(:user, username: "realuser", password: "realpass123")
        victim.sessions.create!(last_active_at: Time.current)
        their_invite = create(:membership, user: victim, organization: org,
                                           role: Membership::ROLE_MEMBER, status: Membership::STATUS_INVITED)
        token = their_invite.mint_invite_token!

        post "/api/v1/members/accept-invite",
             params: { invite_id: token }, headers: auth_headers(victim)

        expect(response).to have_http_status(:ok)
        expect(their_invite.reload.status).to eq(Membership::STATUS_ACTIVE)
        expect(victim.reload.username).to eq("realuser")
      end
    end
  end
end
