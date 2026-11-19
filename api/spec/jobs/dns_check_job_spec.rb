require "rails_helper"

RSpec.describe DnsCheckJob, type: :job do
  let(:owner) { create(:user, username: "dnsjobowner") }

  def stub_checker(mx_ok)
    checks = { mx: mx_ok, spf: mx_ok, dmarc: mx_ok, dkim: mx_ok }
    allow(DnsChecker).to receive(:new).and_return(
      instance_double(DnsChecker, call: { mx_ok: mx_ok, all_ok: mx_ok, checks: checks })
    )
  end

  def domain_with(status, name)
    org = create(:organization, owner: owner, domain: name)
    org.default_domain.tap { |d| d.update!(status: status) }
  end

  it "promotes a pending domain to verified when MX resolves" do
    domain = domain_with("pending_dns", "promote.com")
    stub_checker(true)
    described_class.perform_now(domain.id)
    expect(domain.reload.status).to eq("verified")
  end

  it "demotes a verified domain back to pending when MX breaks" do
    domain = domain_with("verified", "broke.com")
    stub_checker(false)
    described_class.perform_now(domain.id)
    expect(domain.reload.status).to eq("pending_dns")
  end

  it "records the per-record check map so the admin health card has real state" do
    domain = domain_with("pending_dns", "records.com")
    stub_checker(true)
    described_class.perform_now(domain.id)
    expect(domain.reload.dns_checks).to include("mx" => true, "spf" => true, "dmarc" => true, "dkim" => true)
    expect(domain.dns_checked_at).to be_present
  end

  it "refreshes a receiving_mail domain's record map without downgrading its status" do
    domain = domain_with("receiving_mail", "live.com")
    stub_checker(false)
    described_class.perform_now
    expect(domain.reload.status).to eq("receiving_mail")
    expect(domain.dns_checks).to include("mx" => false)
  end
end
