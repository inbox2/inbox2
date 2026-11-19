module Disk
  # Who each listed node is shared with, for the Access column (spec F4):
  # its own grants (the first SHOWN, plus the total) and whether access also
  # comes from above (a share, or a grant on an ancestor). A constant number
  # of queries per page of nodes, whatever its size.
  class SharedWith
    SHOWN = 4

    Entry = Struct.new(:people, :total, :inherited, keyword_init: true)

    # { node_id => Entry } for nodes.
    def self.for(nodes)
      nodes = Array(nodes)
      return {} if nodes.empty?

      ids = nodes.map(&:id)
      ranked = Disk::Grant.where(node_id: ids)
        .select("disk_grants.*, row_number() OVER (PARTITION BY node_id ORDER BY created_at, id) AS rank, " \
                "count(*) OVER (PARTITION BY node_id) AS total")
      grants = Disk::Grant.from(ranked, :disk_grants).where("rank <= ?", SHOWN).order(:rank)
        .includes(membership: :user).group_by(&:node_id)
      above = granted_above(ids)
      nodes.to_h do |n|
        own = grants[n.id] || []
        [n.id, Entry.new(people: own, total: own.first&.total.to_i, inherited: n.share_id.present? || above.include?(n.id))]
      end
    end

    # Ids among node_ids with a grant on some ancestor.
    def self.granted_above(node_ids)
      Disk::Node.connection.select_values(Disk::Node.sanitize_sql([<<~SQL.squish, node_ids])).to_set
        WITH RECURSIVE a(start_id, id) AS (
          SELECT id, parent_id FROM disk_nodes WHERE id IN (?)
          UNION ALL
          SELECT a.start_id, n.parent_id FROM disk_nodes n JOIN a ON n.id = a.id WHERE n.parent_id IS NOT NULL
        ) SELECT DISTINCT a.start_id FROM a JOIN disk_grants g ON g.node_id = a.id
      SQL
    end
  end
end
