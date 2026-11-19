require "rails_helper"

RSpec.describe DnsChecker do
  let(:owner) { create(:user, username: "dnsowner") }
  let(:org) { create(:organization, owner: owner, domain: "checkme.com") }

  # A fake resolver returning canned records (no network).
  def resolver(mx: [], txt: {}, cname: {})
    fake = Object.new
    fake.define_singleton_method(:mx) { |_| mx }
    fake.define_singleton_method(:txt) { |host| txt[host] || [] }
    fake.define_singleton_method(:cname) { |host| cname[host] }
    fake
  end

  it "passes every check when DNS is fully configured" do
    r = resolver(
      mx: ["mx.inbox2.com."],
      txt: {
        "checkme.com" => ["v=spf1 include:_spf.inbox2.com ~all"],
        "_dmarc.checkme.com" => ["v=DMARC1; p=quarantine"]
      },
      cname: { "inbox2._domainkey.checkme.com" => "inbox2._domainkey.inbox2.com." },
    )
    result = described_class.new(org.default_domain, resolver: r).call
    expect(result[:mx_ok]).to be(true)
    expect(result[:all_ok]).to be(true)
    expect(result[:checks]).to eq(mx: true, spf: true, dmarc: true, dkim: true)
  end

  it "matches MX case-insensitively and ignores a trailing dot" do
    r = resolver(mx: ["MX.Inbox2.Com"])
    expect(described_class.new(org.default_domain, resolver: r).call[:mx_ok]).to be(true)
  end

  it "reports mx_ok false and partial checks when records are missing" do
    r = resolver(mx: ["aspmx.l.google.com."], txt: { "checkme.com" => ["v=spf1 include:_spf.inbox2.com ~all"] })
    result = described_class.new(org.default_domain, resolver: r).call
    expect(result[:mx_ok]).to be(false)
    expect(result[:all_ok]).to be(false)
    expect(result[:checks][:spf]).to be(true)
    expect(result[:checks][:dmarc]).to be(false)
  end

  it "treats a fully empty resolver as unconfigured" do
    result = described_class.new(org.default_domain, resolver: resolver).call
    expect(result[:checks].values).to all(be(false))
  end
end
