# Per-period auto-triage usage counter backing the triage circuit breaker.
# One row per (organization, scope_type, scope_id, period); `period` is a
# calendar month "YYYY-MM" so counters reset monthly (aligns with billing).
#
# `triaged_count` is the number of triages that actually called Jev and is
# what the per-plan caps are checked against. `throttled_count` records triages
# skipped because a cap was hit — kept purely for observability while we watch
# real usage before deciding on overage billing.
class AiTriageUsage < ApplicationRecord
  belongs_to :organization

  SCOPE_ORG = "org".freeze
  SCOPE_DOMAIN = "domain".freeze
  SCOPE_USER = "user".freeze

  # Counter column per recorded kind. A fixed whitelist so the column name is
  # never interpolated from caller input.
  COLUMNS = { triaged: "triaged_count", throttled: "throttled_count" }.freeze

  def self.period_for(time = Time.current)
    time.strftime("%Y-%m")
  end

  def self.count_for(organization_id, scope_type, scope_id, period)
    where(organization_id:, scope_type:, scope_id:, period:).pick(:triaged_count) || 0
  end

  # Atomically +1 the given counter for one scope/period in a single statement,
  # creating the row on first use — no read-then-write race, no retry. `kind` is
  # :triaged or :throttled.
  def self.increment!(organization_id, scope_type, scope_id, period, kind)
    col = COLUMNS.fetch(kind)
    connection.execute(sanitize_sql_array([<<~SQL, organization_id, scope_type, scope_id, period]))
      INSERT INTO ai_triage_usages (organization_id, scope_type, scope_id, period, #{col}, created_at, updated_at)
      VALUES (?, ?, ?, ?, 1, NOW(), NOW())
      ON CONFLICT (organization_id, scope_type, scope_id, period)
      DO UPDATE SET #{col} = ai_triage_usages.#{col} + 1, updated_at = NOW()
    SQL
  end
end
