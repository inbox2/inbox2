require "rails_helper"

RSpec.describe CloudflareDns do
  let(:domain_record) { instance_double("Domain", name: "example.test") }
  let(:service) { described_class.new("cf-token") }

  before do
    # Zone lookup resolves example.test → a zone id.
    allow(service).to receive(:get).with("/zones", hash_including(name: "example.test")).and_return([{ "id" => "zone1", "name" => "example.test" }])
  end

  def stub_records(map)
    # map: { "TXT:example.test" => [records], ... } keyed by "#{type}:#{name}".
    allow(service).to receive(:get) do |path, **query|
      if path == "/zones"
        [{ "id" => "zone1", "name" => "example.test" }]
      else
        map.fetch("#{query[:type]}:#{query[:name]}", [])
      end
    end
  end

  it "raises a clear error when the domain isn't in the account" do
    allow(service).to receive(:get).with("/zones", any_args).and_return([])
    expect { service.apply(domain_record) }.to raise_error(CloudflareDns::Error, /isn.t in this Cloudflare account/)
  end

  it "creates all four records on a clean zone (and DKIM is DNS-only)" do
    stub_records({})
    created = []
    allow(service).to receive(:post) { |_path, body| created << body }

    result = service.apply(domain_record)

    expect(result[:records].map { |r| r[:action] }).to all(eq("created"))
    dkim = created.find { |b| b[:type] == "CNAME" }
    expect(dkim[:proxied]).to be(false) # the whole point — proxied CNAME breaks DKIM
    expect(created.map { |b| b[:type] }).to contain_exactly("MX", "TXT", "TXT", "CNAME")
  end

  it "is idempotent — a second run keeps already-correct records" do
    stub_records({
      "MX:example.test" => [{ "id" => "m", "type" => "MX", "content" => "mx.inbox2.com", "priority" => 10 }],
      "TXT:example.test" => [{ "id" => "s", "type" => "TXT", "content" => "v=spf1 include:_spf.inbox2.com ~all" }],
      "TXT:_dmarc.example.test" => [{ "id" => "d", "type" => "TXT", "content" => "v=DMARC1; p=quarantine" }],
      "CNAME:inbox2._domainkey.example.test" => [{ "id" => "k", "type" => "CNAME", "content" => "inbox2._domainkey.inbox2.com", "proxied" => false }]
    })
    expect(service).not_to receive(:post)
    expect(service).not_to receive(:put)

    result = service.apply(domain_record)
    expect(result[:records].map { |r| r[:action] }).to all(eq("kept"))
  end

  it "merges our include into an existing SPF record without clobbering it" do
    stub_records({ "TXT:example.test" => [{ "id" => "s", "type" => "TXT", "content" => "v=spf1 include:mailgun.org -all" }] })
    put_bodies = []
    allow(service).to receive(:post)
    allow(service).to receive(:put) { |_path, body| put_bodies << body }

    service.apply(domain_record)
    spf = put_bodies.find { |b| b[:content]&.start_with?("v=spf1") }
    expect(spf[:content]).to eq("v=spf1 include:mailgun.org include:_spf.inbox2.com -all")
  end

  it "sees through the quotes Cloudflare wraps TXT content in (never a second SPF or DMARC)" do
    stub_records({
      "TXT:example.test" => [{ "id" => "s", "type" => "TXT", "content" => "\"v=spf1 include:_spf.google.com ~all\"" }],
      "TXT:_dmarc.example.test" => [{ "id" => "d", "type" => "TXT", "content" => "\"v=DMARC1; p=none;\"" }]
    })
    posted = []
    put_bodies = []
    allow(service).to receive(:post) { |_path, body| posted << body }
    allow(service).to receive(:put) { |_path, body| put_bodies << body }

    result = service.apply(domain_record)
    actions = result[:records].to_h { |r| [r[:name], r[:action]] }
    expect(actions["example.test"]).to eq("updated")
    expect(actions["_dmarc.example.test"]).to eq("kept")
    spf = put_bodies.find { |b| b[:content]&.start_with?("v=spf1") }
    expect(spf[:content]).to eq("v=spf1 include:_spf.google.com include:_spf.inbox2.com ~all")
    expect(posted.select { |b| b[:type] == "TXT" }).to be_empty
  end

  it "skips a self-referential DKIM CNAME (setting up the mail domain itself)" do
    # For inbox2.com the DKIM CNAME host == target → Cloudflare would reject it.
    mail_domain = instance_double("Domain", name: DnsRecordsSerializer::MAIL_DOMAIN)
    allow(service).to receive(:get) do |path, **query|
      path == "/zones" ? [{ "id" => "z", "name" => DnsRecordsSerializer::MAIL_DOMAIN }] : []
    end
    posted = []
    allow(service).to receive(:post) { |_p, body| posted << body }

    result = service.apply(mail_domain)
    dkim = result[:records].find { |r| r[:type] == "CNAME" }
    expect(dkim[:action]).to eq("skipped")
    expect(posted.map { |b| b[:type] }).not_to include("CNAME") # never sent → no "references itself" error
  end

  it "does not clobber an existing DMARC policy" do
    stub_records({ "TXT:_dmarc.example.test" => [{ "id" => "d", "type" => "TXT", "content" => "v=DMARC1; p=reject" }] })
    allow(service).to receive(:post)
    allow(service).to receive(:put)
    expect(service).not_to receive(:put)

    result = service.apply(domain_record)
    dmarc = result[:records].find { |r| r[:name] == "_dmarc.example.test" }
    expect(dmarc[:action]).to eq("kept")
  end
end
