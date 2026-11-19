# Aggregates the Command Center mailbox graph.
#
# READ SELECT-ALIASES WITH `row[:alias]`, NEVER `row.alias`. These queries
# project computed columns (address/total/unread/open_unread/mailbox_count/
# weight) that are not real Conversation columns, so ActiveRecord has to define
# the reader lazily on first call. Two SolidQueue worker threads hitting that
# definition at once can leave the generated method PRIVATE for the life of the
# process, and every later run then dies with
#   NoMethodError: private method 'address' called for an instance of Conversation
# — permanently, until the worker restarts. It reproduces only under threads,
# which is why a single-threaded `rails runner` looks fine. `row[:alias]` reads
# the attribute directly and never touches method visibility.
class MailboxGraphAggregator
  DEFAULT_MAX_MAILBOXES = 100
  DEFAULT_MAX_CONTACTS = 150

  def initialize(organization, max_mailboxes: DEFAULT_MAX_MAILBOXES, max_contacts: DEFAULT_MAX_CONTACTS)
    @organization = organization
    @domain = organization.default_domain&.name
    @max_mailboxes = max_mailboxes
    @max_contacts = max_contacts
  end

  # Returns { nodes: [...], links: [...] }
  def call
    base = @organization.conversations.org_readable.where.not(to_address: [nil, ""])

    nodes = []
    mailbox_set = Set.new

    # Layer 1: Mailbox nodes — top N by unread, then by total
    mailbox_rows = base
      .group(:to_address)
      .select(
        "to_address AS address",
        "COUNT(*) AS total",
        "COUNT(*) FILTER (WHERE read = false) AS unread",
        "COUNT(*) FILTER (WHERE status = '#{Conversation::STATUS_OPEN}' AND read = false) AS open_unread",
        "COUNT(*) FILTER (WHERE created_at >= NOW() - INTERVAL '7 days') AS recent7",
        "COUNT(*) FILTER (WHERE created_at >= NOW() - INTERVAL '14 days' AND created_at < NOW() - INTERVAL '7 days') AS prior7",
        "COUNT(*) FILTER (WHERE created_at >= date_trunc('day', NOW())) AS today"
      )
      .order(Arel.sql("unread DESC, COUNT(*) DESC"))
      .limit(@max_mailboxes)

    mailbox_rows.each do |r|
      addr = r[:address]
      mailbox_set.add(addr)
      nodes << {
        id: addr,
        address: addr,
        name: addr.split("@").first,
        type: "mailbox",
        total: r[:total].to_i,
        unread: r[:unread].to_i,
        recent: r[:recent7].to_i,
        prior: r[:prior7].to_i,
        today: r[:today].to_i,
        open_unread: r[:open_unread].to_i
      }
    end

    waiting_by_mailbox = compute_waiting(mailbox_set)
    nodes.each do |n|
      w = waiting_by_mailbox[n[:address]]
      n[:waiting] = w ? w[:waiting] : 0
      n[:waiting_over_24h] = w ? w[:waiting_24h] : 0
      n[:oldest_waiting_at] = w&.dig(:oldest_at)&.iso8601
      wait_hours = w ? (Time.current - w[:oldest_at]) / 3600.0 : 0.0
      n[:urgency] = compute_urgency(n[:total], n[:unread], n.delete(:open_unread), wait_hours)
    end

    # Layer 2: Contact nodes — top N senders by volume, must have >= 2 conversations
    contact_rows = base
      .where.not(from_address: [nil, ""])
      .where(to_address: mailbox_set.to_a)
      .group(:from_address)
      .select(
        "from_address AS address",
        "COUNT(*) AS total",
        "COUNT(DISTINCT to_address) AS mailbox_count"
      )
      .having("COUNT(*) >= 2")
      .order(Arel.sql("COUNT(*) DESC"))
      .limit(@max_contacts)

    contact_set = Set.new
    contact_rows.each do |r|
      addr = r[:address]
      next if mailbox_set.include?(addr)

      contact_set.add(addr)
      local = addr.split("@").first
      is_internal = addr.end_with?("@#{@domain}")
      nodes << {
        id: addr,
        address: addr,
        name: local.gsub(/[._-]/, " ").gsub(/\b\w/, &:capitalize),
        type: is_internal ? "member" : "external",
        total: r[:total].to_i,
        mailbox_count: r[:mailbox_count].to_i
      }
    end

    all_ids = mailbox_set | contact_set

    # Links — only between known nodes
    links = {}

    # Sender -> mailbox links (batched query scoped to known nodes)
    sender_links = base
      .where.not(from_address: [nil, ""])
      .where(from_address: all_ids.to_a, to_address: mailbox_set.to_a)
      .group(:from_address, :to_address)
      .select("from_address", "to_address", "COUNT(*) AS weight")

    sender_links.each do |sl|
      next if sl.from_address == sl.to_address

      key = [sl.from_address, sl.to_address].sort.join("||")
      kind = mailbox_set.include?(sl.from_address) ? "internal" : "inbound"
      links[key] ||= { source: sl.from_address, target: sl.to_address, weight: 0, kind: kind }
      links[key][:weight] += sl[:weight].to_i
    end

    # Shared tag links between mailboxes only
    if mailbox_set.size <= 200
      tag_pairs = base
        .joins(:tags)
        .where(tags: { membership_id: nil })
        .where(to_address: mailbox_set.to_a)
        .group("tags.name", :to_address)
        .pluck("tags.name", :to_address)
        .group_by(&:first)
        .transform_values { |pairs| pairs.map(&:last).uniq }

      tag_pairs.each do |_tag, targets|
        next if targets.length < 2
        targets.combination(2).each do |a, b|
          pair = [a, b].sort
          key = pair.join("||")
          links[key] ||= { source: pair[0], target: pair[1], weight: 0, kind: "shared_tag" }
          links[key][:weight] += 1
        end
      end
    end

    { nodes: nodes, links: links.values, stats: compute_org_stats(base, nodes) }
  end

  def source_version
    stats = @organization.conversations.org_readable
      .where.not(to_address: [nil, ""])
      .pick(Arel.sql("COUNT(*), MAX(updated_at)"))
    count = stats&.first || 0
    max_at = stats&.last&.to_i || 0
    Digest::SHA256.hexdigest("#{@organization.id}:#{count}:#{max_at}")[0..15]
  end

  private

  # Open conversations whose latest non-draft message is inbound = someone is
  # waiting on a reply. Grouped per mailbox: how many, how many for > 24h, and
  # the oldest waiting-since timestamp.
  # ponytail: one LATERAL index lookup per open conversation — fine in the
  # 2-min snapshot job; add a last_message_inbound flag on conversations if an
  # org's open set ever makes this slow.
  def compute_waiting(mailbox_set)
    return {} if mailbox_set.empty?

    rows = @organization.conversations.org_readable
      .where(status: Conversation::STATUS_OPEN, to_address: mailbox_set.to_a)
      .joins(<<~SQL)
        JOIN LATERAL (
          SELECT m.is_inbound, m.created_at
          FROM messages m
          WHERE m.conversation_id = conversations.id AND m.is_draft = false
          ORDER BY m.created_at DESC
          LIMIT 1
        ) lm ON lm.is_inbound
      SQL
      .group(:to_address)
      .select(
        "to_address AS address",
        "COUNT(*) AS waiting",
        "COUNT(*) FILTER (WHERE lm.created_at < NOW() - INTERVAL '24 hours') AS waiting_24h",
        "MIN(lm.created_at) AS oldest_at"
      )

    rows.each_with_object({}) do |r, h|
      h[r[:address]] = {
        waiting: r[:waiting].to_i,
        waiting_24h: r[:waiting_24h].to_i,
        oldest_at: r[:oldest_at]
      }
    end
  end

  # Org-level KPI block for the Explorer stats strip.
  def compute_org_stats(base, nodes)
    totals = base.pick(Arel.sql(<<~SQL))
      COUNT(*) FILTER (WHERE created_at >= date_trunc('day', NOW())),
      COUNT(*) FILTER (WHERE created_at >= NOW() - INTERVAL '7 days'),
      COUNT(*) FILTER (WHERE created_at >= NOW() - INTERVAL '14 days' AND created_at < NOW() - INTERVAL '7 days')
    SQL

    mailboxes = nodes.select { |n| n[:type] == "mailbox" }
    busiest = mailboxes.max_by { |n| [n[:recent], n[:total]] }

    # ponytail: waiting totals sum the top-#{DEFAULT_MAX_MAILBOXES} mailboxes,
    # not every address — same trim the graph itself makes.
    {
      inbound_today: totals&.first.to_i,
      recent7: totals&.second.to_i,
      prior7: totals&.third.to_i,
      waiting: mailboxes.sum { |n| n[:waiting] },
      waiting_over_24h: mailboxes.sum { |n| n[:waiting_over_24h] },
      oldest_waiting_at: mailboxes.filter_map { |n| n[:oldest_waiting_at] }.min,
      busiest: busiest && { address: busiest[:address], recent: busiest[:recent], total: busiest[:total] },
      top_external_domain: top_external_domain(base)
    }
  end

  # External sender domain with the most conversations this week, plus its
  # prior-week count so the frontend can show the delta.
  def top_external_domain(base)
    scope = base
      .where("created_at >= NOW() - INTERVAL '14 days'")
      .where.not(from_address: [nil, ""])
    scope = scope.where.not("from_address LIKE ?", "%@#{@domain}") if @domain

    row = scope
      .group(Arel.sql("split_part(from_address, '@', 2)"))
      .select(
        "split_part(from_address, '@', 2) AS address",
        "COUNT(*) FILTER (WHERE created_at >= NOW() - INTERVAL '7 days') AS recent7",
        "COUNT(*) FILTER (WHERE created_at < NOW() - INTERVAL '7 days') AS prior7"
      )
      .order(Arel.sql("COUNT(*) FILTER (WHERE created_at >= NOW() - INTERVAL '7 days') DESC"))
      .limit(1)
      .first

    return nil unless row && row[:recent7].to_i.positive?

    { domain: row[:address], recent: row[:recent7].to_i, prior: row[:prior7].to_i }
  end

  def compute_urgency(total, unread, open_unread, oldest_wait_hours)
    return 0.0 if total.zero?
    unread_ratio = unread.to_f / total
    open_pressure = [open_unread / 10.0, 1.0].min
    age_pressure = [oldest_wait_hours / 72.0, 1.0].min
    ((unread_ratio * 0.3) + (open_pressure * 0.2) + (age_pressure * 0.5)).round(2)
  end
end
