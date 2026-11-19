module Disk
  # Folder listing filters, sort and name search (spec F2), shared by the REST
  # controllers and the MCP tools so the two cannot drift. `opts` is a hash
  # with string keys: sort, dir, type, modified, tz, since, by, sealed.
  module Listing
    SORTS = {
      "name" => "lower(disk_nodes.name)",
      "modified" => "disk_nodes.content_modified_at",
      "size" => "disk_nodes.size_bytes",
      "by" => "lower(coalesce(nullif(users.display_name, ''), users.username))"
    }.freeze
    SEARCH_LIMIT = 50

    module_function

    def node_scope = Disk::Node.includes(:parent, :share, :current_version, modified_by: :user)

    # [all live children, the filtered and sorted ones] of a folder or page.
    def children(visible, folder, opts, organization)
      raise Disk::Refused, "Only folders and pages have contents" unless folder.container?

      all = node_scope.merge(visible).live.where(parent_id: folder.id, pending_until: nil) # staged nodes stay out of listings
      [all, sorted(filter(all, opts, organization), opts)]
    end

    # Live, unsealed nodes whose name contains q, under scope_node when given.
    def search(visible, q, opts, scope_node: nil)
      q = q.to_s.strip
      raise Disk::Refused, "Type at least one character" if q.empty?

      rel = node_scope.merge(visible).live.where(sealed: false, pending_until: nil).where.not(parent_id: nil)
        .where("lower(disk_nodes.name) LIKE ?", "%#{Disk::Node.sanitize_sql_like(q.downcase)}%")
      rel = rel.where("disk_nodes.id IN (#{Disk::Node.subtree_ids_sql([scope_node.id])})") if scope_node
      modified_filter(rel, opts).order(Arel.sql("lower(disk_nodes.name), disk_nodes.id")).limit(SEARCH_LIMIT).to_a
    end

    def filter(rel, opts, organization)
      families = opts["type"].to_s.split(",").map(&:strip).reject(&:blank?)
      if families.any?
        unknown = families - Disk::Node::FAMILIES
        raise Disk::Refused, "Unknown type: #{unknown.join(', ')}" if unknown.any?

        rel = rel.merge(families.map { |f| Disk::Node.of_family(f) }.reduce(:or))
      end
      rel = modified_filter(rel, opts)
      if opts["by"].present?
        by = organization.memberships.find_by(key: opts["by"].to_s)
        rel = rel.where(modified_by_membership_id: by&.id)
      end
      rel = rel.where(sealed: ActiveModel::Type::Boolean.new.cast(opts["sealed"])) if opts["sealed"].present?
      rel
    end

    # Folders stay above everything else whatever the sort.
    def sorted(rel, opts)
      column = SORTS[opts["sort"].to_s] || SORTS["name"]
      dir = opts["dir"].to_s == "desc" ? "DESC" : "ASC"
      rel = rel.left_joins(modified_by: :user) if opts["sort"].to_s == "by"
      rel.order(Arel.sql("(disk_nodes.kind = 'folder') DESC, #{column} #{dir} NULLS LAST, disk_nodes.id #{dir}"))
    end

    # modified=7d (whole days), modified=today (since the start of the day in
    # tz, an IANA zone, default UTC), or since=<ISO 8601 time>, which wins.
    def modified_filter(rel, opts)
      from = if opts["since"].present?
        Time.iso8601(opts["since"].to_s)
      elsif opts["modified"].to_s == "today"
        zone = ActiveSupport::TimeZone[opts["tz"].presence || "UTC"] || raise(Disk::Refused, "Unknown time zone")
        zone.now.beginning_of_day
      elsif opts["modified"].present?
        days = opts["modified"].to_s[/\A(\d+)d\z/, 1] || raise(Disk::Refused, "modified must be today or look like 7d")
        days.to_i.days.ago
      end
      from ? rel.where(disk_nodes: { content_modified_at: from.. }) : rel
    rescue ArgumentError
      raise Disk::Refused, "since must be an ISO 8601 time"
    end
  end
end
