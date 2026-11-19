class Plan < ApplicationRecord
  key_prefix "plan"

  # ── Canonical tiers ──────────────────────────────────────────────────────────
  # `tier` is the stable identity the codebase branches on — free / paid / max.
  # `name` is just the user-facing label (seeded from DEFAULTS below); the
  # frontend owns the displayed copy, so a marketing rename is only a label
  # change and never touches plan logic.
  TIER_FREE = "free".freeze
  TIER_PAID = "paid".freeze
  TIER_MAX = "max".freeze
  TIERS = [TIER_FREE, TIER_PAID, TIER_MAX].freeze

  # Default display labels (current marketing names). Referenced by DEFAULTS and
  # by the SaaS plan API + specs that address plans by display name.
  NAME_FREE = "Free".freeze
  NAME_STARTUP = "Startup".freeze
  NAME_SERIAL = "Serial Entrepreneur".freeze

  # Sentinel value for an uncapped limit (domains / collaborators) on paid tiers.
  UNLIMITED = 999_999

  # Monthly auto-triage circuit-breaker caps per tier (see TriageBreaker). Sized
  # at ~10% of plan revenue at ~$0.00006/triage; the per-domain / per-user
  # sub-caps stop one domain or mailbox from draining the whole org's budget.
  # Free never triages server-side, so its caps are 0. Hard caps for now — over
  # a cap we skip the LLM and drop to the holding pen (no overage billing yet).
  AI_TRIAGE_LIMITS = {
    TIER_FREE => { org: 0, domain: 0, user: 0 },
    TIER_PAID => { org: 30_000, domain: 20_000, user: 12_000 },
    TIER_MAX => { org: 80_000, domain: 50_000, user: 30_000 }
  }.freeze

  # IMAP and SMTP access for other mail clients (docs/Mail-Clients.md) comes
  # with every paid tier (decided 2026-11-11).
  def mail_clients? = tier != TIER_FREE

  # ESP: API sends (one per recipient) an org may make in a calendar month
  # (docs/ESP.md). Free gets none; over the allowance the API answers 429.
  ESP_MONTHLY_SENDS = { TIER_FREE => 0, TIER_PAID => 10_000, TIER_MAX => 50_000 }.freeze

  def esp_monthly_sends = ESP_MONTHLY_SENDS.fetch(tier, 0)

  def self.ai_triage_limits(tier)
    AI_TRIAGE_LIMITS[tier] || AI_TRIAGE_LIMITS[TIER_FREE]
  end

  # Disk pool per active member, by tier (docs/plans/disk-build.md section 1;
  # 10 on paid and 30 on max, decided 2026-10-03).
  DISK_GB_PER_MEMBER = { TIER_FREE => 0, TIER_PAID => 10, TIER_MAX => 30 }.freeze

  # Disk comes with every paid tier: there is no switch (decided 2026-10-03).
  # The `disk` and `disk_gb_per_member` columns are no longer read or written;
  # they stay until the next migration roll-up so a rolling deploy never has an
  # old pod reading a dropped column.
  def disk? = tier != TIER_FREE
  def disk_gb_per_member = DISK_GB_PER_MEMBER.fetch(tier, 0)

  # Per-tier seed defaults. `max_collaborators` = seats ON TOP OF the primary owner
  # (other owners count; Organization#collaborator_count).
  DEFAULTS = {
    TIER_FREE => { name: NAME_FREE, price_cents: 0, max_domains: 1, max_collaborators: 0,
                   max_message_size_mb: 20, spam_filter: false, ai_triage: false, e2ee: false },
    TIER_PAID => { name: NAME_STARTUP, price_cents: 1999, interval: "month", max_domains: 2,
                   max_collaborators: 2, max_message_size_mb: 100, spam_filter: true, ai_triage: true,
                   e2ee: true },
    TIER_MAX => { name: NAME_SERIAL, price_cents: 4999, interval: "month", max_domains: UNLIMITED,
                  max_collaborators: UNLIMITED, max_message_size_mb: 100, spam_filter: true, ai_triage: true,
                  e2ee: true }
  }.freeze

  has_many :subscriptions

  validates :name, presence: true
  validates :tier, inclusion: { in: TIERS }, allow_nil: true

  def unlimited_domains?
    max_domains >= UNLIMITED
  end

  def unlimited_collaborators?
    max_collaborators >= UNLIMITED
  end

  def free?
    tier == TIER_FREE
  end

  def paid?
    tier == TIER_PAID
  end

  def max?
    tier == TIER_MAX
  end

  # Display order: free → paid → max.
  def rank
    TIERS.index(tier) || 99
  end

  # ── Canonical tier accessors (idempotent) ────────────────────────────────────
  def self.free
    ensure_tier(TIER_FREE)
  end

  def self.paid
    ensure_tier(TIER_PAID)
  end

  def self.max
    ensure_tier(TIER_MAX)
  end

  # Find-or-create the canonical row for a tier. Adopts a legacy row matched by
  # its display name (rows that predate the `tier` column) by stamping the tier,
  # so this never creates a duplicate on an existing deployment.
  def self.ensure_tier(tier)
    plan = find_by(tier: tier) || find_by(name: DEFAULTS[tier][:name])
    if plan
      plan.update!(tier: tier) if plan.tier != tier
      plan
    else
      create!(DEFAULTS[tier].merge(tier: tier))
    end
  end

  # Read-path guard: the rows exist after the first boot, so a GET must not pay
  # for three upserts + two UPDATEs every time (it did on /plans and subscribe).
  def self.ensure_seeded!
    seed_defaults! unless where(tier: TIERS).count == TIERS.size
  end

  def self.seed_defaults!
    free
    paid
    max
    # Reconcile the paid-only feature flags on already-existing rows.
    where(tier: [TIER_PAID, TIER_MAX]).update_all(ai_triage: true, e2ee: true)
    where(tier: TIER_FREE).update_all(ai_triage: false, e2ee: false)
  end
end
