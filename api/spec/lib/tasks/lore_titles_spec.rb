require "rails_helper"
require "rake"

RSpec.describe "lore:titles" do
  before(:all) { Rails.application.load_tasks if Rake::Task.tasks.none? { |t| t.name == "lore:titles" } }

  let(:owner) { create(:user, username: "titlesowner") }
  let(:org) { create(:organization, owner: owner, domain: "titles.com") }
  let(:llm) { instance_double(Llm::Client, configured?: true) }

  def thread(label:, title: nil, status: Conversation::STATUS_OPEN)
    conv = create(:conversation, organization: org, subject: "factuurnummer 1186795", triage_label: label,
                                 next_action_title: title, status: status)
    create(:message, organization: org, conversation: conv, body_plain: "Graag betalen", is_inbound: true)
    conv
  end

  def run_task
    Rake::Task["lore:titles"].reenable
    expect { Rake::Task["lore:titles"].invoke(org.key, "10") }.to output(/lore:titles/).to_stdout
  end

  before do
    allow(Llm::Client).to receive(:default).and_return(llm)
    allow_any_instance_of(Organization).to receive(:ai_triage_enabled?).and_return(true)
  end

  it "titles open Lore items lacking one, and only those" do
    todo = thread(label: TriageLabel::PAYMENT_DUE)
    titled = thread(label: TriageLabel::NEEDS_ANSWER, title: "Reply to Sam")
    handled = thread(label: TriageLabel::FYI)
    archived = thread(label: TriageLabel::PAYMENT_DUE, status: Conversation::STATUS_ARCHIVED)
    allow_any_instance_of(TriageBreaker).to receive(:allow?).and_return(true)
    expect(llm).to receive(:complete).once.and_return('{"summary":"Invoice","title":"Pay invoice 1186795"}')

    run_task
    expect(todo.reload.next_action_title).to eq("Pay invoice 1186795")
    expect(titled.reload.next_action_title).to eq("Reply to Sam")
    expect([handled, archived].map { |c| c.reload.next_action_title }).to all(be_nil)
  end

  it "skips threads once the breaker throttles" do
    thread(label: TriageLabel::PAYMENT_DUE)
    allow_any_instance_of(TriageBreaker).to receive(:allow?).and_return(false)
    expect(llm).not_to receive(:complete)
    run_task
  end
end
