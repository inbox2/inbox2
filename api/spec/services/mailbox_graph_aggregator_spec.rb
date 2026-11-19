require "rails_helper"

RSpec.describe MailboxGraphAggregator do
  let(:owner) { create(:user) }
  let(:org) { create(:organization, owner: owner, domain: "test.com") }

  before do
    # Create mailbox-addressed conversations with tags
    tag_finance = create(:tag, name: "Finance", organization: org)
    tag_hr = create(:tag, name: "HR", organization: org)

    # finance@ gets 3 conversations, 2 unread
    c1 = create(:conversation, organization: org, to_address: "finance@test.com", from_address: "alice@test.com", read: false, status: "open")
    c2 = create(:conversation, organization: org, to_address: "finance@test.com", from_address: "bob@external.com", read: false, status: "open")
    create(:conversation, organization: org, to_address: "finance@test.com", from_address: "alice@test.com", read: true, status: "open")

    # hr@ gets 2 conversations, 1 unread
    c4 = create(:conversation, organization: org, to_address: "hr@test.com", from_address: "alice@test.com", read: false, status: "open")
    create(:conversation, organization: org, to_address: "hr@test.com", from_address: "carol@test.com", read: true, status: "open")

    # bob@ sends a second conversation so he meets the >= 2 threshold
    create(:conversation, organization: org, to_address: "hr@test.com", from_address: "bob@external.com", read: true, status: "open")

    # Shared tag: finance and hr both have Finance tag
    c1.tags << tag_finance
    c2.tags << tag_finance
    c4.tags << tag_hr

    # c1: last message inbound 2 days ago → waiting (and > 24h)
    create(:message, conversation: c1, is_inbound: true, created_at: 2.days.ago)
    # c2: inbound then an outbound reply → answered, not waiting
    create(:message, conversation: c2, is_inbound: true, created_at: 3.days.ago)
    create(:message, conversation: c2, is_inbound: false, created_at: 1.day.ago)
    # c4: last message inbound 1 hour ago → waiting, but not yet 24h
    create(:message, conversation: c4, is_inbound: true, created_at: 1.hour.ago)
  end

  describe "#call" do
    subject { described_class.new(org).call }

    it "returns nodes and links keys" do
      expect(subject).to have_key(:nodes)
      expect(subject).to have_key(:links)
    end

    it "includes mailbox nodes with correct counts" do
      mailboxes = subject[:nodes].select { |n| n[:type] == "mailbox" }
      expect(mailboxes.length).to eq(2)

      finance = mailboxes.find { |n| n[:address] == "finance@test.com" }
      expect(finance).to be_present
      expect(finance[:total]).to eq(3)
      expect(finance[:unread]).to eq(2)
      expect(finance[:urgency]).to be > 0
    end

    it "includes contact/sender nodes" do
      contacts = subject[:nodes].reject { |n| n[:type] == "mailbox" }
      addresses = contacts.map { |n| n[:address] }
      expect(addresses).to include("bob@external.com")
    end

    it "classifies internal senders as member type" do
      contacts = subject[:nodes].reject { |n| n[:type] == "mailbox" }
      alice = contacts.find { |n| n[:address] == "alice@test.com" }
      expect(alice[:type]).to eq("member")
    end

    it "classifies external senders as external type" do
      contacts = subject[:nodes].reject { |n| n[:type] == "mailbox" }
      bob = contacts.find { |n| n[:address] == "bob@external.com" }
      expect(bob[:type]).to eq("external")
    end

    it "computes waiting counts and oldest waiting age per mailbox" do
      mailboxes = subject[:nodes].select { |n| n[:type] == "mailbox" }
      finance = mailboxes.find { |n| n[:address] == "finance@test.com" }
      hr = mailboxes.find { |n| n[:address] == "hr@test.com" }

      # finance: c1 waiting (inbound 2 days ago, > 24h); c2 answered; c3 has no messages
      expect(finance[:waiting]).to eq(1)
      expect(finance[:waiting_over_24h]).to eq(1)
      expect(Time.iso8601(finance[:oldest_waiting_at])).to be_within(5.seconds).of(2.days.ago)

      # hr: c4 waiting 1 hour, not yet over 24h
      expect(hr[:waiting]).to eq(1)
      expect(hr[:waiting_over_24h]).to eq(0)
    end

    it "includes weekly trend counts per mailbox" do
      finance = subject[:nodes].find { |n| n[:address] == "finance@test.com" }
      expect(finance[:recent]).to eq(3)
      expect(finance[:prior]).to eq(0)
      expect(finance[:today]).to eq(3)
    end

    it "includes an org-level stats block" do
      stats = subject[:stats]
      expect(stats[:inbound_today]).to eq(6)
      expect(stats[:recent7]).to eq(6)
      expect(stats[:prior7]).to eq(0)
      expect(stats[:waiting]).to eq(2)
      expect(stats[:waiting_over_24h]).to eq(1)
      expect(stats[:oldest_waiting_at]).to be_present
      expect(stats[:busiest][:address]).to eq("finance@test.com")
      expect(stats[:top_external_domain][:domain]).to eq("external.com")
      expect(stats[:top_external_domain][:recent]).to eq(2)
    end

    it "creates sender-to-mailbox links" do
      inbound = subject[:links].select { |l| l[:kind] == "inbound" }
      expect(inbound.length).to be > 0
    end

    it "creates shared sender links when a sender emails multiple mailboxes" do
      # alice@test.com sends to both finance@ and hr@, creating a link
      links = subject[:links]
      alice_links = links.select { |l|
        [l[:source], l[:target]].include?("alice@test.com")
      }
      expect(alice_links.length).to be >= 2
    end
  end

  describe "#source_version" do
    it "returns a hex string" do
      version = described_class.new(org).source_version
      expect(version).to match(/\A[0-9a-f]+\z/)
    end

    it "changes when conversations change" do
      v1 = described_class.new(org).source_version
      create(:conversation, organization: org, to_address: "new@test.com", from_address: "x@y.com")
      v2 = described_class.new(org).source_version
      expect(v1).not_to eq(v2)
    end
  end

  describe "urgency calculation" do
    it "returns 0 for empty mailboxes" do
      empty_org = create(:organization, owner: owner, domain: "empty.com")
      result = described_class.new(empty_org).call
      expect(result[:nodes]).to be_empty
    end
  end

  # Regression: in production the graph job died every 2 minutes with
  #   NoMethodError: private method 'address' called for an instance of Conversation
  # SELECT aliases have no column behind them, so ActiveRecord generates the
  # reader on first call; two SolidQueue worker threads racing that definition
  # could leave it private for the life of the process. Reading via
  # `row[:alias]` bypasses method lookup, so a privatised reader is harmless.
  describe "SELECT-alias reads" do
    ALIASES = %i[address total unread open_unread recent7 prior7 today waiting waiting_24h oldest_at mailbox_count weight].freeze

    before do
      ALIASES.each do |name|
        Conversation.send(:define_method, name) { raise "reader should not be called" }
        Conversation.send(:private, name)
      end
    end

    after do
      ALIASES.each { |name| Conversation.send(:remove_method, name) }
    end

    it "builds the graph without calling the generated readers" do
      result = described_class.new(org).call

      expect(result[:nodes]).not_to be_empty
      expect(result[:nodes].map { |n| n[:address] }).to include("finance@test.com")
      expect(result[:nodes].find { |n| n[:address] == "finance@test.com" }[:total]).to eq(3)
      expect(result[:links]).not_to be_empty
    end
  end
end
