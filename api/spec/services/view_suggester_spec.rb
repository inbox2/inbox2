require "rails_helper"

RSpec.describe ViewSuggester do
  let(:owner) { create(:user, username: "vsowner") }
  let(:org) { create(:organization, owner: owner, domain: "vstest.com") }
  let!(:membership) { create(:membership, user: owner, organization: org, role: Membership::ROLE_OWNER, status: Membership::STATUS_ACTIVE) }

  subject { described_class.new(org) }

  describe "#suggest" do
    it "suggests views for frequent sender domains (spec 3.3.8)" do
      4.times do |i|
        create(:conversation, organization: org, from_address: "user#{i}@bigclient.com")
      end

      suggestions = subject.suggest
      domain_suggestion = suggestions.find { |s| s[:name] == "From bigclient.com" }
      expect(domain_suggestion).to be_present
      expect(domain_suggestion[:filters].first["value"]).to eq("@bigclient.com")
      expect(domain_suggestion[:reason]).to include("4 conversations")
    end

    it "suggests views for frequently used tags" do
      tag = create(:tag, organization: org, name: "urgent")
      3.times do
        conv = create(:conversation, organization: org)
        conv.tags << tag
      end

      suggestions = subject.suggest
      tag_suggestion = suggestions.find { |s| s[:name] == "Tagged: urgent" }
      expect(tag_suggestion).to be_present
      expect(tag_suggestion[:filters].first["value"]).to eq("urgent")
    end

    it "skips domains with fewer than 3 conversations" do
      2.times { |i| create(:conversation, organization: org, from_address: "u#{i}@rare.com") }

      suggestions = subject.suggest
      expect(suggestions.none? { |s| s[:name] == "From rare.com" }).to be true
    end

    it "does not suggest views that already exist" do
      4.times { |i| create(:conversation, organization: org, from_address: "u#{i}@existing.com") }
      create(:view, organization: org, kind: View::KIND_PERSONAL, membership: membership, name: "Existing",
        filters: [{ "field" => "sender", "operator" => "ends_with", "value" => "@existing.com" }])

      suggestions = subject.suggest
      expect(suggestions.none? { |s| s[:name] == "From existing.com" }).to be true
    end

    it "limits to 5 suggestions" do
      6.times do |i|
        5.times { |j| create(:conversation, organization: org, from_address: "u#{j}@domain#{i}.com") }
      end

      suggestions = subject.suggest
      expect(suggestions.length).to be <= 5
    end
  end
end
