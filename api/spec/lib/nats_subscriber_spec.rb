require "rails_helper"
require Rails.root.join("lib/nats_subscriber")

# The MX server resolves a recipient domain → org via this NATS responder. Under
# the multi-domain model it looks up the Domain and returns the *domain's* status.
RSpec.describe NatsSubscriber, "#handle_domain_lookup" do
  let(:subscriber) { NatsSubscriber.allocate } # skip initialize (no NATS connection)

  def lookup(domain)
    responded = nil
    msg = Object.new
    msg.define_singleton_method(:data) { JSON.generate({ "domain" => domain }) }
    msg.define_singleton_method(:respond) { |json| responded = json }
    subscriber.send(:handle_domain_lookup, msg)
    JSON.parse(responded)
  end

  it "resolves a known domain and returns its status + org + size cap" do
    org = create(:organization, domain: "mx-lookup.test")
    org.default_domain.update!(status: "receiving_mail")

    res = lookup("mx-lookup.test")
    expect(res["found"]).to be(true)
    expect(res["org_key"]).to eq(org.key)
    expect(res["status"]).to eq("receiving_mail")
    expect(res["max_message_size_mb"]).to eq(org.effective_plan.max_message_size_mb)
  end

  it "accepts mail for the ESP bounce domain, which belongs to no org (spec 21.3.5)" do
    res = lookup(Esp::BOUNCE_DOMAIN)
    expect(res).to include("found" => true, "status" => "receiving_mail", "e2ee" => false)
  end

  it "routes an ESP delivery result to its delivery and schedules the retry (spec 21.3.3)" do
    delivery = create(:esp_delivery)
    delivery.claim!
    msg = Object.new
    msg.define_singleton_method(:data) do
      JSON.generate({ "delivery_status_key" => "#{delivery.key}:1", "result" => "transient_failure", "smtp_code" => "451" })
    end
    acked = false
    msg.define_singleton_method(:ack) { acked = true }
    expect { subscriber.send(:process_delivery_status, msg) }
      .to have_enqueued_job(Esp::DeliverJob).with(delivery.id)
    expect(acked).to be(true)
    expect(delivery.reload.status).to eq("deferred")
  end

  it "returns not found for an unknown domain" do
    expect(lookup("nope.test")["found"]).to be(false)
  end

  it "returns not found for a billing-locked domain (mail bounces)" do
    org = create(:organization, domain: "locked.test")
    org.default_domain.update!(status: "receiving_mail", locked_at: Time.current)
    expect(lookup("locked.test")["found"]).to be(false)
  end

  it "resolves a secondary (non-primary) domain with its own status" do
    org = create(:organization, domain: "primary.test")
    create(:domain, organization: org, name: "second.test", status: "verified")

    res = lookup("second.test")
    expect(res["found"]).to be(true)
    expect(res["org_key"]).to eq(org.key)
    expect(res["status"]).to eq("verified")
  end

  describe "E2EE decision (docs/E2EE.md Phase A)" do
    def entitled_sealed_org(name, keyed: true)
      org = create(:organization, domain: name)
      org.update!(plan: create(:plan, e2ee: true))
      create(:domain_key, domain: org.default_domain) if keyed
      # update_column: the enabled-but-keyless case bypasses the model guard to
      # model historic/edge states the resolver must still handle safely.
      org.default_domain.update_column(:e2ee_enabled, true)
      org
    end

    def stub_force_off(value)
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with("INBOX2_E2EE_FORCE_OFF", anything).and_return(value)
    end

    it "reports e2ee false while force-off (the dev/test default)" do
      entitled_sealed_org("forced-off.test")

      expect(lookup("forced-off.test")["e2ee"]).to be(false)
    end

    it "returns the sealing material for an entitled, enabled, keyed domain" do
      stub_force_off("false")
      org = entitled_sealed_org("sealed.test")
      dk = org.default_domain.current_e2ee_key

      res = lookup("sealed.test")
      expect(res["e2ee"]).to be(true)
      expect(res["e2ee_public_key"]).to eq(dk.public_key)
      expect(res["e2ee_key_version"]).to eq(1)
      expect(res["domain_id"]).to eq(org.default_domain.id)
      expect(res["e2ee_notification_preview"]).to be(true) # rich alerts by default (accepted risk)
    end

    it "ships the content-free opt-OUT to the MX" do
      stub_force_off("false")
      org = entitled_sealed_org("paranoid.test")
      org.default_domain.update_column(:e2ee_notification_preview, false)

      expect(lookup("paranoid.test")["e2ee_notification_preview"]).to be(false)
    end

    it "reports e2ee false for an enabled-but-keyless domain (plaintext fallback, never half-seal)" do
      stub_force_off("false")
      entitled_sealed_org("keyless.test", keyed: false)

      res = lookup("keyless.test")
      expect(res["found"]).to be(true)
      expect(res["e2ee"]).to be(false)
      expect(res).not_to have_key("e2ee_public_key")
    end

    it "reports e2ee false for an unentitled org even with the switch forced on" do
      stub_force_off("false")
      org = create(:organization, domain: "unentitled.test")
      org.default_domain.update_column(:e2ee_enabled, true) # simulate a downgrade
      create(:domain_key, domain: org.default_domain)

      expect(lookup("unentitled.test")["e2ee"]).to be(false)
    end
  end
end
