require "rails_helper"

RSpec.describe SpamFeedbackJob do
  let(:owner) { create(:user, username: "feedbackowner") }
  let(:org) { create(:organization, owner: owner, domain: "feedback.com") }
  let(:client) { instance_double(RspamdClient, train_spam: true, train_ham: true) }

  before { allow(RspamdClient).to receive(:new).and_return(client) }

  it "trains spam and junk-lists the sender for every conversation in the list" do
    convs = 2.times.map do |i|
      conv = create(:conversation, organization: org, status: Conversation::STATUS_SPAM)
      create(:message, conversation: conv, organization: org, is_inbound: true,
             from_address: "spammer#{i}@junk.com", body_plain: "Buy now")
      conv
    end

    described_class.perform_now(convs.map(&:id), true)

    expect(client).to have_received(:train_spam).twice
    expect(org.mail_filters.where(kind: MailFilter::KIND_JUNK).pluck(:value))
      .to match_array([ "spammer0@junk.com", "spammer1@junk.com" ])
  end

  it "trains ham and un-junks the sender on release" do
    conv = create(:conversation, organization: org, status: Conversation::STATUS_OPEN)
    create(:message, conversation: conv, organization: org, is_inbound: true,
           from_address: "friend@good.com", body_plain: "Real mail")
    MailFilter.create!(organization: org, kind: MailFilter::KIND_JUNK, value: "friend@good.com")

    described_class.perform_now([ conv.id ], false)

    expect(client).to have_received(:train_ham)
    expect(org.mail_filters.where(kind: MailFilter::KIND_JUNK)).to be_empty
  end

  it "swallows a training failure so the junk filter still updates" do
    conv = create(:conversation, organization: org, status: Conversation::STATUS_SPAM)
    create(:message, conversation: conv, organization: org, is_inbound: true,
           from_address: "spammer@junk.com", body_plain: "Buy now")
    allow(client).to receive(:train_spam).and_raise(StandardError, "rspamd down")

    expect { described_class.perform_now([ conv.id ], true) }.not_to raise_error
    expect(org.mail_filters.where(kind: MailFilter::KIND_JUNK).pluck(:value)).to eq([ "spammer@junk.com" ])
  end
end
