require "rails_helper"

RSpec.describe Plan, type: :model do
  it "seeds the three tiers with the right limits, prices and order" do
    Plan.seed_defaults!
    free = Plan.free
    startup = Plan.paid
    serial = Plan.max

    expect([free.max_domains, free.max_collaborators, free.price_cents]).to eq([1, 0, 0])
    expect([startup.max_domains, startup.max_collaborators, startup.price_cents]).to eq([2, 2, 1999])
    expect(serial.price_cents).to eq(4999)
    expect(serial.unlimited_domains?).to be(true)
    expect(serial.unlimited_collaborators?).to be(true)

    # Canonical tier identity (decoupled from the display name).
    expect([free.tier, startup.tier, serial.tier]).to eq([Plan::TIER_FREE, Plan::TIER_PAID, Plan::TIER_MAX])
    # Display order rank.
    expect([free.rank, startup.rank, serial.rank]).to eq([0, 1, 2])
    expect([free.free?, startup.paid?, serial.max?]).to eq([true, true, true])
    expect(startup.free?).to be(false)

    # AI triage (OpenAI classifier) is a paid-only feature.
    expect(free.ai_triage).to be(false)
    expect(startup.ai_triage).to be(true)
    expect(serial.ai_triage).to be(true)

    # E2EE message sealing is a paid-only entitlement (docs/E2EE.md).
    expect(free.e2ee).to be(false)
    expect(startup.e2ee).to be(true)
    expect(serial.e2ee).to be(true)
  end

  it "adopts a legacy row (name set, tier nil) without creating a duplicate" do
    legacy = Plan.create!(name: Plan::NAME_STARTUP, price_cents: 1999, max_domains: 2,
                          max_collaborators: 2, max_message_size_mb: 100, spam_filter: true)
    expect(legacy.tier).to be_nil

    expect { Plan.paid }.not_to change(Plan, :count)
    expect(legacy.reload.tier).to eq(Plan::TIER_PAID)
  end
end
