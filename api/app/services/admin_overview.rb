# Aggregate operational stats for the MX admin console (/admin), scoped to one
# organization. The web console fans this out across the user's domains and sums
# the raw counts client-side, so everything here is returned as plain counts /
# per-day series rather than pre-rounded percentages.
class AdminOverview
  SERIES_DAYS = 7

  # domain: when given, every stat is narrowed to that one domain's slice of the
  # org pool (per-domain console cards). Nil = the whole org (all domains summed).
  def initialize(organization, now: Time.current, domain: nil)
    @org = organization
    @now = now
    @domain = domain
  end

  def call
    {
      inbound: flow(inbound: true),
      outbound: flow(inbound: false),
      spam: spam_counts,
      classification: classification_counts,
      unrouted: unrouted_count,
      pool: pool_counts
    }
  end

  private

  # Base relations, optionally narrowed to one domain's slice of the pool.
  def conversations_scope
    @domain ? @org.conversations.where(domain_id: @domain.id) : @org.conversations
  end

  def messages_scope
    @domain ? @org.messages.where(conversation_id: conversations_scope.select(:id)) : @org.messages
  end

  def today_start
    @today_start ||= @now.beginning_of_day
  end

  # Start of the rolling 7-day window (inclusive of today) and of the preceding
  # 7-day window, so every time-based stat shares one window and deltas compare
  # like for like (this week vs last week).
  def window_start
    @window_start ||= today_start - (SERIES_DAYS - 1).days
  end

  def prev_window_start
    @prev_window_start ||= window_start - SERIES_DAYS.days
  end

  # Mail throughput over the last 7 days, with the prior 7 days for the delta.
  def flow(inbound:)
    scope = messages_scope.where(is_inbound: inbound, is_draft: false)
    {
      last7: scope.where("created_at >= ?", window_start).count,
      prev7: scope.where(created_at: prev_window_start...window_start).count,
      series: daily_series(scope)
    }
  end

  # Counts for the last SERIES_DAYS days, oldest first, zero-filled.
  def daily_series(scope)
    by_day = scope.where("created_at >= ?", window_start).group("DATE(created_at)").count
    (0...SERIES_DAYS).map do |i|
      day = (window_start + i.days).to_date
      by_day[day] || by_day[day.to_s] || 0
    end
  end

  # Rspamd writes a spam_action per scanned inbound message; anything past
  # "no action" was flagged/blocked. Counted over the same 7-day window as flow.
  def spam_counts
    scanned = messages_scope.where(is_inbound: true).where.not(spam_action: nil)
                  .where("created_at >= ?", window_start)
    { scanned_7d: scanned.count, blocked_7d: scanned.where.not(spam_action: "no action").count }
  end

  # What fraction of open conversations the classifier has routed into a Space.
  def classification_counts
    open = conversations_scope.where(status: Conversation::STATUS_OPEN)
    { classified: open.where.not(space_id: nil).count, classifiable: open.count }
  end

  # Open conversations the classifier hasn't placed yet (the holding-pen backlog).
  def unrouted_count
    conversations_scope.where(status: Conversation::STATUS_OPEN, space_id: nil).count
  end

  # Open-pool counts — the live inbox, the same scope as classification/unrouted
  # (excludes archived/trash/spam) so Emails/Unread reconcile with the routing
  # numbers and with what a member actually sees in the inbox.
  def pool_counts
    convs = conversations_scope.where(status: Conversation::STATUS_OPEN)
    { volume: convs.count, unread: convs.where(read: false).count }
  end
end
