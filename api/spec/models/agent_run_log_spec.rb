require "rails_helper"

RSpec.describe AgentRunLog, type: :model do
  let(:owner) { create(:user, username: "arlowner") }
  let(:org) { create(:organization, owner: owner, domain: "arltest.com") }
  let!(:membership) { create(:membership, user: owner, organization: org, role: Membership::ROLE_OWNER, status: Membership::STATUS_ACTIVE) }

  let(:agent_user) { create(:user, username: "arlagent") }
  let!(:agent_membership) { create(:membership, user: agent_user, organization: org, role: Membership::ROLE_MEMBER, status: Membership::STATUS_ACTIVE, member_type: Membership::TYPE_AGENT) }
  let(:agent) { create(:agent, organization: org, membership: agent_membership) }

  describe "Agent#record_run!" do
    it "creates a run log and increments counters (spec 5.5.8)" do
      expect {
        agent.record_run!(
          action: "reply",
          status: AgentRunLog::STATUS_SUCCESS,
          duration_ms: 150,
          cost_cents: 5
        )
      }.to change(AgentRunLog, :count).by(1)

      expect(agent.reload.total_runs).to eq(1)
      expect(agent.total_spend_cents).to eq(5)
    end

    it "generates a key for the log" do
      log = agent.record_run!(action: "tag", status: AgentRunLog::STATUS_SUCCESS)
      expect(log.key).to start_with("arl_")
    end
  end

  describe "Agent#rate_limited?" do
    it "returns true when rate limit exceeded (spec 5.5.9)" do
      agent.update!(rate_limit: 2)
      2.times { agent.record_run!(action: "read", status: AgentRunLog::STATUS_SUCCESS) }

      expect(agent.rate_limited?).to be true
    end

    it "returns false when under limit" do
      agent.update!(rate_limit: 10)
      agent.record_run!(action: "read", status: AgentRunLog::STATUS_SUCCESS)

      expect(agent.rate_limited?).to be false
    end

    it "returns false when rate_limit is zero (unlimited)" do
      agent.update!(rate_limit: 0)
      expect(agent.rate_limited?).to be false
    end
  end

  describe "Agent#spend_limited?" do
    it "returns true when spend limit reached" do
      agent.update!(spend_limit_cents: 10)
      agent.record_run!(action: "reply", status: AgentRunLog::STATUS_SUCCESS, cost_cents: 10)

      expect(agent.spend_limited?).to be true
    end

    it "returns false when under spend limit" do
      agent.update!(spend_limit_cents: 100)
      agent.record_run!(action: "reply", status: AgentRunLog::STATUS_SUCCESS, cost_cents: 5)

      expect(agent.spend_limited?).to be false
    end
  end
end
