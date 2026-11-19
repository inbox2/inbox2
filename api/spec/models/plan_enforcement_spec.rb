require "rails_helper"

# Plan enforcement is now org-scoped (PlanEnforcement folded into Organization).
RSpec.describe "Organization plan enforcement", type: :model do
  let(:org) { create(:organization) }

  describe "#on_free_plan?" do
    it "is true with no subscription" do
      expect(org.on_free_plan?).to eq(true)
    end

    it "is false when subscribed to a paid plan" do
      create(:subscription, organization: org, plan: Plan.max)
      expect(org.reload.on_free_plan?).to eq(false)
    end
  end

  describe "#domain_limit_reached?" do
    it "is reached on Free (1 domain) and lifts on Paid" do
      expect(org).to be_domain_limit_reached
      create(:subscription, organization: org, plan: Plan.max)
      expect(org.reload).not_to be_domain_limit_reached
    end
  end

  describe "#effective_mail_size_limit" do
    it "reflects the effective plan" do
      expect(org.effective_mail_size_limit).to eq(Plan.free.max_message_size_mb * 1_048_576)
      create(:subscription, organization: org, plan: Plan.max)
      expect(org.reload.effective_mail_size_limit).to eq(Plan.max.max_message_size_mb * 1_048_576)
    end
  end
end
