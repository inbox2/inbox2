# Circuit breaker for server-side AI auto-triage (SpaceClassifier, which calls
# Jev and, for new threads, OpenAI for the summary). Enforces the per-plan monthly caps at three nested scopes —
# org, recipient domain, and recipient mailbox owner (user) — so one runaway
# domain or mailbox can't drain the whole org's budget or rack up cost.
#
# A triage is allowed only when EVERY applicable scope is under its cap. On an
# allowed triage we +1 each scope's triaged_count; on a throttled one we +1
# throttled_count (observability) and the caller drops the thread into the
# holding pen without ever calling Jev.
#
# Attribution is best-effort: org is always known; domain/user are resolved from
# the recipient address when possible (shared/space aliases have no mailbox, so
# they fall under the domain + org caps only).
class TriageBreaker
  # Null-object breaker for classifier callers without usage context (tests,
  # non-MX paths): always allows and records nothing, so #classify never has to
  # special-case a missing breaker.
  class Null
    def allow? = true
    def record_triaged!; end
    def record_throttled!; end
  end

  def initialize(organization, domain: nil, membership: nil, period: AiTriageUsage.period_for)
    @organization = organization
    @domain = domain
    @membership = membership
    @period = period
    @limits = Plan.ai_triage_limits(organization.effective_plan.tier)
  end

  # True when every applicable scope is still under its monthly cap.
  def allow?
    scopes.all? { |type, id, limit| AiTriageUsage.count_for(@organization.id, type, id, @period) < limit }
  end

  def record_triaged!
    bump_all(:triaged)
  end

  def record_throttled!
    bump_all(:throttled)
  end

  private

  # [scope_type, scope_id, cap] for each scope that applies to this triage.
  def scopes
    list = [[AiTriageUsage::SCOPE_ORG, @organization.id, @limits[:org]]]
    list << [AiTriageUsage::SCOPE_DOMAIN, @domain.id, @limits[:domain]] if @domain
    list << [AiTriageUsage::SCOPE_USER, @membership.id, @limits[:user]] if @membership
    list
  end

  def bump_all(kind)
    scopes.each { |type, id, _| AiTriageUsage.increment!(@organization.id, type, id, @period, kind) }
  end
end
