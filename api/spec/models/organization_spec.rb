require "rails_helper"

RSpec.describe Organization, type: :model do
  describe "validations & associations" do
    subject { build(:organization) }

    it { should validate_presence_of(:name) }
    it { should validate_inclusion_of(:view_creation_policy).in_array(Organization::VIEW_POLICIES) }
    it { should belong_to(:owner).class_name("User").optional }
    it { should have_many(:domains).dependent(:destroy) }
    it { should have_many(:memberships).dependent(:destroy) }
    it { should have_one(:subscription).dependent(:destroy) }
  end

  it "generates a public ID with org_ prefix (E5)" do
    expect(create(:organization).key).to start_with("org_")
  end

  describe "slug" do
    it "never takes a top-level web path such as /disk" do
      expect(create(:organization, name: "Disk").slug).to eq("disk-1")
      expect(create(:organization, name: "Acme Disk").slug).to eq("acme-disk")
    end
  end

  describe "#effective_plan" do
    it "prefers the per-org override, then subscription, then Free" do
      org = create(:organization)
      expect(org.effective_plan.name).to eq(Plan::NAME_FREE)

      create(:subscription, organization: org, plan: Plan.max)
      expect(org.reload.effective_plan.name).to eq(Plan::NAME_SERIAL)

      org.update!(plan: Plan.free)
      expect(org.reload.effective_plan.name).to eq(Plan::NAME_FREE)
    end
  end

  describe "domains" do
    it "exposes the default (oldest) domain and all names" do
      org = create(:organization, domain: "primary.test")
      create(:domain, organization: org, name: "extra.test")
      expect(org.default_domain.name).to eq("primary.test")
      expect(org.domain_names).to match_array(%w[primary.test extra.test])
    end
  end

  describe "#domain_limit_reached?" do
    it "caps domains per org by the effective plan (Free = 1)" do
      org = create(:organization)
      expect(org).to be_domain_limit_reached
      create(:subscription, organization: org, plan: Plan.max)
      expect(org.reload).not_to be_domain_limit_reached
    end
  end

  describe "mailbox cap" do
    it "counts mailboxes and applies the override" do
      org = create(:organization, domain: "d.test")
      m = create(:membership, organization: org)
      create(:mailbox, membership: m, domain: org.default_domain, local_part: "a")
      expect(org.mailbox_count).to eq(1)

      org.update!(mailbox_limit: 1)
      expect(org).to be_mailbox_limit_reached
      expect(org).to be_mailbox_override_reached
    end
  end

  describe "collaborator cap (every seat but the primary owner's)" do
    it "counts active members other than the primary owner and applies the plan limit" do
      org = create(:organization)
      create(:membership, organization: org, user: org.owner, role: "owner") # the one free seat
      expect(org.collaborator_count).to eq(0)
      expect(org).to be_collaborator_limit_reached # Free = 0

      create(:subscription, organization: org, plan: Plan.paid) # 2 seats
      create(:membership, organization: org, user: create(:user), role: "member", status: "active")
      expect(org.reload.collaborator_count).to eq(1)
      expect(org).not_to be_collaborator_limit_reached

      create(:membership, organization: org, user: create(:user), role: "member", status: "active")
      expect(org.reload).to be_collaborator_limit_reached # 2/2

      org.subscription.update!(plan: Plan.max)
      expect(org.reload).not_to be_collaborator_limit_reached # unlimited
    end
  end

  it "counts a second owner as a collaborator" do
    org = create(:organization)
    create(:membership, organization: org, user: org.owner, role: "owner")
    create(:membership, organization: org, user: create(:user), role: "owner")
    expect(org.collaborator_count).to eq(1)
    expect(org).to be_collaborator_limit_reached # Free = 0
  end

  it "counts a pending invite as a taken seat" do
    org = create(:organization)
    create(:subscription, organization: org, plan: Plan.paid) # 2 seats
    create(:membership, organization: org, user: org.owner, role: "owner")
    create(:membership, organization: org, user: create(:user), role: "member", status: "active")
    create(:membership, organization: org, user: create(:user), role: "owner", status: "invited")
    expect(org.collaborator_count).to eq(2)
    expect(org).to be_collaborator_limit_reached
  end

  it "withdraws pending invites before locking active seats on downgrade" do
    org = create(:organization)
    create(:subscription, organization: org, plan: Plan.max)
    create(:membership, organization: org, user: org.owner, role: "owner")
    member = create(:membership, organization: org, user: create(:user), role: "member", status: "active")
    invite = create(:membership, organization: org, user: create(:user), role: "owner", status: "invited")

    org.apply_plan_limits!(Plan.paid.tap { |p| p.max_collaborators = 1 })

    expect(Membership.exists?(invite.id)).to be(false)
    expect(member.reload.status).to eq("active")
  end

  it "restores billing-locked seats only into seats invites have not taken" do
    org = create(:organization)
    create(:membership, organization: org, user: org.owner, role: "owner")
    locked = create(:membership, organization: org, user: create(:user), role: "member", status: "disabled", billing_locked_at: 1.day.ago)
    create(:membership, organization: org, user: create(:user), role: "member", status: "invited")
    create(:membership, organization: org, user: create(:user), role: "member", status: "invited")

    org.apply_plan_limits!(Plan.paid) # 2 seats, both held by invites

    expect(locked.reload.status).to eq("disabled")
  end

  it "gives the free seat to an owner, not to a primary owner demoted to member" do
    org = create(:organization)
    create(:membership, organization: org, user: org.owner, role: "member", status: "active")
    other_owner = create(:membership, organization: org, user: create(:user), role: "owner", status: "active")
    expect(org.free_seat_membership).to eq(other_owner)
    expect(org.collaborator_count).to eq(1)
  end

  it "reports a change that moved the free seat and went over the cap" do
    org = create(:organization)
    primary = create(:membership, organization: org, user: org.owner, role: "owner", status: "disabled")
    create(:membership, organization: org, user: create(:user), role: "owner", status: "active") # holds the free seat
    before = org.collaborator_count
    expect(before).to eq(0)

    primary.update!(status: "active") # the primary takes the free seat back; the other owner now counts
    expect(org.seats_exceeded_since?(before)).to be(true) # Free: 0 seats
  end

  it "leaves one owner free when the org has no primary owner" do
    org = create(:organization)
    create(:membership, organization: org, user: create(:user), role: "owner")
    create(:membership, organization: org, user: create(:user), role: "owner")
    org.update!(owner: nil)
    expect(org.collaborator_count).to eq(1)
  end

  it "locks a plain member before an extra owner on downgrade" do
    org = create(:organization)
    create(:subscription, organization: org, plan: Plan.max)
    create(:membership, organization: org, user: org.owner, role: "owner")
    second_owner = create(:membership, organization: org, user: create(:user), role: "owner", status: "active")
    members = Array.new(2) { create(:membership, organization: org, user: create(:user), role: "member", status: "active") }

    org.apply_plan_limits!(Plan.paid) # 2 seats for 3 counted members

    expect(second_owner.reload.status).to eq("active")
    expect(members.first.reload.status).to eq("active")
    expect(members.last.reload.status).to eq("disabled")
  end

  describe "#downgrade_impact / #apply_plan_limits!" do
    it "reports the excess and locks newest domains + disables newest collaborators" do
      org = create(:organization, domain: "primary.test")
      create(:subscription, organization: org, plan: Plan.max)
      second = create(:domain, organization: org, name: "second.test")
      collab = create(:membership, organization: org, user: create(:user), role: "member", status: "active")

      impact = org.downgrade_impact(Plan.free)
      expect(impact).to eq(domains_over: 1, collaborators_over: 1)
      expect(org.over_plan_limits?(Plan.free)).to be(true)

      org.apply_plan_limits!(Plan.free)
      expect(org.default_domain.reload).not_to be_locked          # primary kept
      expect(second.reload).to be_locked                          # newest locked
      expect(collab.reload.status).to eq(Membership::STATUS_DISABLED)
    end

    it "unlocks kept domains on upgrade" do
      org = create(:organization, domain: "primary.test")
      second = create(:domain, organization: org, name: "second.test", locked_at: Time.current)
      create(:subscription, organization: org, plan: Plan.max)

      org.apply_plan_limits!(Plan.max)
      expect(second.reload).not_to be_locked
    end

    it "tags downgrade-disabled collaborators billing-locked and re-enables them on upgrade" do
      org = create(:organization, domain: "primary.test")
      create(:subscription, organization: org, plan: Plan.max)
      collab = create(:membership, organization: org, user: create(:user), role: "member", status: "active")
      manual = create(:membership, organization: org, user: create(:user), role: "member", status: "disabled")

      org.apply_plan_limits!(Plan.free) # 0 collaborator seats
      expect(collab.reload.status).to eq(Membership::STATUS_DISABLED)
      expect(collab.billing_locked?).to be(true)

      org.subscription.update!(plan: Plan.max)
      org.apply_plan_limits!(Plan.max) # unlimited seats
      expect(collab.reload.status).to eq(Membership::STATUS_ACTIVE)
      expect(collab.billing_locked?).to be(false)
      # A manually-disabled member is never auto-restored.
      expect(manual.reload.status).to eq(Membership::STATUS_DISABLED)
    end

    it "restores billing-locked seats only up to the new limit" do
      org = create(:organization, domain: "primary.test")
      create(:subscription, organization: org, plan: Plan.max)
      3.times { create(:membership, organization: org, user: create(:user), role: "member", status: "active") }

      org.apply_plan_limits!(Plan.free)        # disables all 3
      expect(org.collaborator_count).to eq(0)

      org.subscription.update!(plan: Plan.paid)
      org.apply_plan_limits!(Plan.paid)     # 2 seats → restore only 2
      expect(org.reload.collaborator_count).to eq(2)
      expect(org.memberships.where(status: Membership::STATUS_DISABLED).where.not(billing_locked_at: nil).count).to eq(1)
    end
  end

  it "suspends and unsuspends" do
    org = create(:organization)
    org.suspend!("abuse")
    expect(org).to be_suspended
    org.unsuspend!
    expect(org).not_to be_suspended
  end

  it "exposes owner memberships (multi-owner)" do
    org = create(:organization)
    create(:membership, organization: org, user: create(:user), role: "owner")
    create(:membership, organization: org, user: create(:user), role: "owner")
    expect(org.owner_memberships.count).to eq(2)
  end
end
