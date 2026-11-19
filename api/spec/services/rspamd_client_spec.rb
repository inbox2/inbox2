require "rails_helper"

RSpec.describe RspamdClient do
  let(:client) { described_class.new(url: "http://rspamd.test:11334") }

  describe "#check" do
    it "returns a neutral result on connection failure" do
      result = client.check("From: test@example.com\r\n\r\nBody")
      expect(result.score).to eq(0.0)
      expect(result.action).to eq("no action")
      expect(result.spam?).to be false
    end

    it "returns a CheckResult struct with expected fields" do
      result = client.check("From: test@example.com\r\n\r\nBody")
      expect(result).to respond_to(:score, :action, :symbols, :required_score, :spam?)
    end
  end

  describe "CheckResult#spam?" do
    it "returns true when score >= threshold" do
      result = RspamdClient::CheckResult.new(score: 8.5, action: "reject", symbols: [], required_score: 7.0)
      expect(result.spam?).to be true
      expect(result.spam?(10.0)).to be false
    end

    it "returns false when score < threshold" do
      result = RspamdClient::CheckResult.new(score: 3.2, action: "no action", symbols: [], required_score: 7.0)
      expect(result.spam?).to be false
    end

    it "uses required_score as default threshold" do
      result = RspamdClient::CheckResult.new(score: 5.0, action: "add header", symbols: [], required_score: 4.0)
      expect(result.spam?).to be true
    end
  end

  describe "#train_spam / #train_ham" do
    it "returns false on connection failure without raising" do
      expect(client.train_spam("From: spam@bad.com\r\n\r\nBuy now!")).to be false
      expect(client.train_ham("From: friend@good.com\r\n\r\nHello")).to be false
    end
  end

  describe "#healthy?" do
    it "returns false when Rspamd is unreachable" do
      expect(client.healthy?).to be false
    end
  end
end
