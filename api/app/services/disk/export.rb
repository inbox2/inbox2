module Disk
  # The org's Disk export (spec F11) for owners and admins: a manifest and,
  # page by page, every live item in the team's shares with its path in the
  # export (`D/<share>/...`), a short-lived presigned URL for each unsealed file's
  # current version, and each unsealed page's markdown. The browser fetches the
  # files straight from storage and builds the archive; no bytes pass through
  # Rails. Sealed items are listed as encrypted and not included; trash and old
  # versions are left out. A person's own C:\ is theirs and is in no admin's
  # export (decided 2026-10-07 and 2026-11-09); they export it themselves.
  class Export
    PAGE = 200
    NOTE = "Current versions of unsealed files and pages only. Trash and older versions are not included. " \
           "Sealed files and pages are listed as encrypted and not included.".freeze

    # scope_key: a sealed node's scope (its public id, no name), so a browser holding that
    # scope's key can add a sealed page as markdown (spec F7); the server never can.
    Entry = Struct.new(:node, :path, :url, :expires_at, :markdown, :scope_key, keyword_init: true)
    Manifest = Struct.new(:organization, :generated_at, :note, :members, :shares, :share_members, :grants, :links,
                          :paths, :totals, keyword_init: true)

    attr_reader :organization

    def initialize(organization)
      @organization = organization
    end

    def manifest
      shares = Disk::Share.where(organization_id: organization.id).live.includes(:root_node).order(:name).to_a
      grants = Disk::Grant.joins(:node).merge(live_nodes).includes(:node, membership: :user, granted_by: :user).to_a
      links = Disk::Link.joins(:node).merge(live_nodes).active.includes(:node, created_by: :user).to_a
      Manifest.new(
        organization: organization, generated_at: Time.current, note: NOTE, members: members, shares: shares,
        share_members: Disk::ShareMembership.where(share_id: shares.map(&:id)).includes(membership: :user).group_by(&:share_id),
        grants: grants, links: links, paths: paths_for(grants.map(&:node) + links.map(&:node)),
        totals: { items: live_nodes.where.not(parent_id: nil).count,
                  sealed: live_nodes.where(sealed: true).count,
                  bytes: Disk::Version.joins(:node).merge(live_nodes).where("disk_nodes.current_version_id = disk_versions.id")
                                     .where(disk_nodes: { sealed: false }).sum(:size_bytes) }
      )
    end

    # [entries, next_cursor] for one page of the export.
    def entries(cursor)
      offset = cursor.to_s.match?(/\A\d+\z/) ? cursor.to_i : 0
      rows = live_nodes.where.not(parent_id: nil).includes(:current_version, :page).order(:id)
        .offset(offset).limit(PAGE + 1).to_a
      page = rows.first(PAGE)
      paths = paths_for(page)
      storage = Disk::Storage.current
      expires = Disk::Storage::GET_URL_TTL.from_now
      scopes = Disk::Node.where(id: page.filter_map(&:seal_scope_node_id).uniq).pluck(:id, :key).to_h
      entries = page.map do |n|
        url = n.current_version && !n.sealed? ? storage.get_url(n.current_version.storage_key, filename: n.name) : nil
        Entry.new(node: n, path: paths[n.id], url: url, expires_at: url && expires,
                  markdown: n.page? && !n.sealed? ? n.page&.markdown.to_s : nil, scope_key: scopes[n.seal_scope_node_id])
      end
      [entries, rows.size > PAGE ? (offset + PAGE).to_s : nil]
    end

    private

    # Live nodes in the team's live shares. Never a C:\ drive.
    def live_nodes
      live_shares = Disk::Share.where(organization_id: organization.id).live.select(:id)
      Disk::Node.where(organization_id: organization.id, share_id: live_shares).live
    end

    def members
      @members ||= organization.memberships.where(member_type: Membership::TYPE_HUMAN).includes(:user).to_a
    end

    # { node id => "D/Marketing/Launch/plan.md" }. A sealed name is its id.
    def paths_for(nodes)
      Disk::Node.paths_for(nodes.uniq).transform_values do |chain|
        head = "D/#{safe(chain.first.share&.name.to_s)}"
        rest = chain.drop(1)
        names = rest.map.with_index do |n, i|
          name = n.sealed? ? "#{n.key} (sealed)" : n.name
          # A page is a .md file; its sub-pages sit in a folder of its own name.
          i == rest.size - 1 && n.page? && !n.sealed? && !name.downcase.end_with?(".md") ? "#{name}.md" : name
        end
        ([head] + names).join("/")
      end
    end

    def safe(name) = name.tr("/\\", "__")
  end
end
