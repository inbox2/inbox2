require "rails_helper"

# Webhook action + run-log behavior added alongside the real HTTP delivery path.
RSpec.describe RuleExecutor, "webhook action + run log" do
  let(:owner) { create(:user, username: "rulewhkowner") }
  let(:org) { create(:organization, owner: owner, domain: "rulewhk.com") }
  let!(:membership) { create(:membership, user: owner, organization: org, role: Membership::ROLE_OWNER, status: Membership::STATUS_ACTIVE) }
  let(:conv) { create(:conversation, organization: org, subject: "Hi") }
  let(:message) { create(:message, conversation: conv, organization: org, from_address: "security@facebookmail.com", to_address: "khuram@rulewhk.com") }
  let(:webhook) { create(:webhook, organization: org, url: "https://example.com/hook") }

  def webhook_rule
    create(:rule, organization: org,
                  conditions: [{ "field" => "from", "operator" => "contains", "value" => "facebook" }],
                  actions: [{ "type" => "webhook", "value" => webhook.key }])
  end

  it "enqueues a delivery job when a webhook rule matches" do
    webhook_rule
    expect(WebhookDeliveryJob).to receive(:perform_later).with(webhook.id, conv.id, message.id, kind_of(Integer))
    RuleExecutor.new(org).execute_for(conv, message)
  end

  it "does not enqueue for a disabled webhook" do
    webhook.update!(enabled: false)
    webhook_rule
    expect(WebhookDeliveryJob).not_to receive(:perform_later)
    RuleExecutor.new(org).execute_for(conv, message)
  end

  it "writes a run log for a matched rule" do
    rule = webhook_rule
    allow(WebhookDeliveryJob).to receive(:perform_later)
    expect { RuleExecutor.new(org).execute_for(conv, message) }.to change { rule.rule_logs.count }.by(1)
    expect(rule.rule_logs.last.actions_taken).to include("webhook:#{webhook.key}")
  end

  it "applies to existing mail via apply_rule (backfill path)" do
    rule = webhook_rule
    allow(WebhookDeliveryJob).to receive(:perform_later)
    result = RuleExecutor.new(org).apply_rule(rule, conv, message)
    expect(result[:matched]).to be(true)
    expect(WebhookDeliveryJob).to have_received(:perform_later)
  end
end
