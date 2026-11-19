# Reputation-based outbound throttling for mail sent through inbox2's OWN
# SMTP (MX mode — docs/Mail-Deliverability.md). Mail sent via a member's
# external provider (Gmail/Office365/IMAP channels) never touches this path
# and is deliberately not limited here.
#
# Young orgs get tight caps so a fresh signup can't burn the shared sending
# IP / domain reputation. Limits grow with BOTH account age and a track
# record of real delivered mail (age alone doesn't earn volume), and
# disappear entirely once the org is 6 months old.
class SendQuota
  Tier = Struct.new(:min_age, :min_delivered, :hourly, :daily, :max_recipients, :label, keyword_init: true)

  # A tier applies when the org is at least min_age old AND has at least
  # min_delivered lifetime delivered recipients. The highest applicable tier
  # wins; the 6-month tier is unconditional (nil limits → unlimited).
  TIERS = [
    Tier.new(min_age: 0,        min_delivered: 0,   hourly: 15,  daily: 125,   max_recipients: 10,  label: "new account"),
    Tier.new(min_age: 1.week,   min_delivered: 25,  hourly: 50,  daily: 400,   max_recipients: 25,  label: "1+ week"),
    Tier.new(min_age: 1.month,  min_delivered: 150, hourly: 150, daily: 1_200, max_recipients: 50,  label: "1+ month"),
    Tier.new(min_age: 3.months, min_delivered: 750, hourly: 400, daily: 4_000, max_recipients: 100, label: "3+ months"),
    Tier.new(min_age: 6.months, min_delivered: 0,   hourly: nil, daily: nil,   max_recipients: nil, label: "established")
  ].freeze

  def initialize(organization)
    @org = organization
  end

  # Comma-separated to/cc strings → recipient count (min 1: a message always
  # costs at least one send even when addresses are sealed/unparseable).
  def self.count_recipients(*address_fields)
    n = address_fields.compact.sum { |f| f.to_s.split(",").count { |a| a.strip.present? } }
    [n, 1].max
  end

  def tier
    @tier ||= begin
      age = Time.current - @org.created_at
      TIERS.select { |t| age >= t.min_age && lifetime_delivered >= t.min_delivered }.last || TIERS.first
    end
  end

  def unlimited?
    tier.hourly.nil?
  end

  # nil when the send may proceed, otherwise a human-readable refusal.
  def deny_reason(recipients: 1)
    # Orgs routing outbound through their OWN ESP (SendGrid/SES/Mailgun/…)
    # spend that provider's reputation, not our shared SMTP IP — no caps.
    return nil if external_esp?
    return nil if unlimited?

    if recipients > tier.max_recipients
      return "This message has #{recipients} recipients — #{tier.label} senders can address at most " \
        "#{tier.max_recipients} recipients per message. Limits grow with account age and delivery history."
    end
    if sent_since(1.hour.ago) + recipients > tier.hourly
      return "Hourly sending limit reached (#{tier.hourly}/hour for #{tier.label} senders) — try again in a bit. " \
        "Limits grow with account age and delivery history."
    end
    if sent_since(24.hours.ago) + recipients > tier.daily
      return "Daily sending limit reached (#{tier.daily}/24h for #{tier.label} senders) — try again tomorrow. " \
        "Limits grow with account age and delivery history."
    end
    nil
  end

  private

  # True when the org's active default delivery channel is a customer-owned
  # ESP — OutboundMailPublisher routes to the provider adapter instead of our
  # Go MTA, so our sending reputation isn't in play.
  def external_esp?
    channel = DeliveryChannel.active_for(@org)
    channel.present? && !channel.builtin?
  end

  # Recipients accepted for delivery in the window. Counted from outbound
  # non-draft messages at acceptance time — a slow queue must not grant a
  # spammer extra headroom.
  def sent_since(t)
    recent_sends.sum { |created_at, *addresses| created_at >= t ? self.class.count_recipients(*addresses) : 0 }
  end

  # One pluck covers both windows (the hourly check used to repeat the daily one).
  # ponytail: recipients are still counted in Ruby over a day of sends; move the
  # split/count into SQL when an org sends more than ~10k messages a day.
  def recent_sends
    @recent_sends ||= @org.messages.where(is_inbound: false, is_draft: false)
      .where(created_at: 24.hours.ago..)
      .pluck(:created_at, :to_address, :cc_address, :bcc_address)
  end

  # Lifetime recipients that actually delivered (the "real sends" reputation
  # signal — bounces and failures don't count).
  def lifetime_delivered
    @lifetime_delivered ||= DeliveryStatus
      .joins(:message)
      .where(messages: { organization_id: @org.id })
      .where(status: DeliveryStatus::STATUS_DELIVERED)
      .count
  end
end
