module Disk
  # The one access function (docs/plans/disk-build.md section 5).
  #
  #   role(member, node) = highest of
  #     manage            node is on C:\ and member is its custodian
  #     manage            member is an org owner or admin and node is in a share
  #     membership role   node is in a share the member belongs to
  #     org_role      node's share is open to the org (to its team's domain, when it has one)
  #     grant role        a grant to the member on node or an ancestor
  #   none of these -> the node does not exist for this member (404, never 403)
  #
  # A trashed share exists only for owners and admins. An archived share is
  # read-only for everyone else. Owners and admins get nothing on other
  # people's C:\.
  #
  # Agents (build guide 9c) take a separate path: an agent membership reaches
  # only what was granted to its agent (Disk::AgentGrant) on a node or an
  # ancestor, capped by the granter's current role there, never sealed nodes,
  # never through share membership or org-open shares. Its role is at most edit,
  # except that an agent with disk_manage holding edit where its granter
  # manages gets manage, so the manage tools work and the agent never has more
  # than the person who set it up.
  class Access
    Source = Struct.new(:kind, :role, :node, :share, keyword_init: true)

    SOURCE_CUSTODIAN = :custodian
    SOURCE_ADMIN = :admin
    SOURCE_SHARE_MEMBER = :share_member
    SOURCE_SHARE_DEFAULT = :share_default
    SOURCE_GRANT = :grant
    SOURCE_AGENT_GRANT = :agent_grant

    # Shares whose contents this member reaches through the share itself.
    def self.visible_shares(membership)
      shares = Disk::Share.where(organization_id: membership.organization_id)
      return shares.none if membership.agent?
      return shares if membership.admin?

      mine = Disk::ShareMembership.where(membership_id: membership.id).select(:share_id)
      # A whole-org share (no domain) is the team's: not for a mailbox-only member.
      open_domains = membership.org_wide_access? ? [nil, *membership.accessible_domain_ids] : membership.accessible_domain_ids
      open = shares.live.where(openness: Disk::Share::OPENNESS_ORG, domain_id: open_domains)
      open.or(shares.live.where(id: mine))
    end

    # Every node this member can see. Controllers never query Disk::Node without it.
    # ponytail: one recursive CTE over grant subtrees per query; materialise
    # grant reach if listing gets slow with many grants.
    def self.scope_for(membership)
      return agent_scope(membership) if membership.agent?

      # This team's nodes, and the person's own C:\ (their personal workspace, 2026-10-07).
      nodes = Disk::Node.where(organization_id: [membership.organization_id, membership.user.personal_organization.id])
      granted = Disk::Grant.where(membership_id: membership.disk_ids).select(:node_id)
      live_shares = Disk::Share.where(organization_id: membership.organization_id).live.select(:id)
      share_nodes = nodes.where(share_id: visible_shares(membership).select(:id))
      if membership.admin?
        # Owners and admins see a sealed share's top folder, not its contents,
        # unless they are its members (build guide 6.2).
        mine = Disk::ShareMembership.where(membership_id: membership.id).select(:share_id)
        share_nodes = share_nodes.where("NOT disk_nodes.sealed OR disk_nodes.parent_id IS NULL " \
                                        "OR disk_nodes.share_id IN (#{mine.to_sql})")
      end
      # A grant reaches sealed nodes only when it is on their scope root, so a
      # grant on a folder above a sealed C:\ folder does not reach into it.
      # A grant is explicit, so it reaches a node on anyone's C:\ (another personal workspace).
      grant_nodes = Disk::Node.where("disk_nodes.id IN (#{Disk::Node.subtree_ids_sql(granted)})")
        .where("disk_nodes.share_id IS NULL OR disk_nodes.share_id IN (#{live_shares.to_sql})")
        .where("NOT disk_nodes.sealed OR disk_nodes.seal_scope_node_id IN (#{granted.to_sql})")
      # Staged nodes exist only for their creator; switched sources for no one (6.8).
      nodes.where(custodian_membership_id: membership.personal_membership_id).or(share_nodes).or(grant_nodes)
        .where("disk_nodes.switched_at IS NULL AND (disk_nodes.pending_until IS NULL " \
               "OR disk_nodes.created_by_membership_id IN (?))", membership.disk_ids)
    end

    # Where this member's access to node comes from. `path` is node's chain
    # from its root (Disk::Node.paths_for), passed in when already loaded;
    # `preload` is what roles_for loaded for a whole page of nodes.
    def self.sources(membership, node, path: nil, preload: nil)
      return agent_sources(membership, node, path: path) if membership.agent?

      out = []
      out << Source.new(kind: SOURCE_CUSTODIAN, role: Disk::ROLE_MANAGE) if membership.custodian_of?(node)
      share = node.share
      return out if share&.trashed? && !membership.admin?

      if share
        if membership.admin? && (!node.sealed? || node.root?)
          out << Source.new(kind: SOURCE_ADMIN, role: Disk::ROLE_MANAGE, share: share)
        end
        sm = preload ? preload[:share_memberships][share.id] : share.share_memberships.find_by(membership_id: membership.id)
        out << Source.new(kind: SOURCE_SHARE_MEMBER, role: sm.role, share: share) if sm
        open = preload ? share.open_to_org? && (share.domain_id.nil? ? membership.org_wide_access? : preload[:domain_ids].include?(share.domain_id)) : share.open_to?(membership)
        out << Source.new(kind: SOURCE_SHARE_DEFAULT, role: share.org_role, share: share) if open
      end
      ids = (path || node.path).map(&:id)
      ids &= [node.seal_scope_node_id] if node.sealed? # sealed: only a grant on the scope root counts
      grants = preload ? preload[:grants].values_at(*ids).flatten.compact : Disk::Grant.where(membership_id: membership.disk_ids, node_id: ids).includes(:node)
      grants.each { |g| out << Source.new(kind: SOURCE_GRANT, role: g.role, node: g.node) }
      out
    end

    # The member's effective role on node, or nil when it does not exist for them.
    def self.role(membership, node, path: nil, preload: nil)
      role = sources(membership, node, path: path, preload: preload).map(&:role).max_by { |r| Disk.role_rank(r) }
      return role unless role && node.share&.archived? && !membership.admin?

      Disk::ROLE_VIEW
    end

    # { node id => role } for a page of nodes, in a fixed number of queries.
    def self.roles_for(membership, nodes)
      paths = Disk::Node.paths_for(nodes)
      preload = unless membership.agent?
        { share_memberships: Disk::ShareMembership.where(membership_id: membership.id, share_id: nodes.filter_map(&:share_id).uniq)
            .index_by(&:share_id),
          domain_ids: membership.accessible_domain_ids.to_set,
          grants: Disk::Grant.where(membership_id: membership.disk_ids, node_id: paths.values.flatten.map(&:id).uniq)
            .includes(:node).group_by(&:node_id) }
      end
      nodes.to_h { |n| [n.id, role(membership, n, path: paths[n.id], preload: preload)] }
    end

    def self.allows?(membership, node, needed, path: nil)
      Disk.role_rank(role(membership, node, path: path)) >= Disk.role_rank(needed)
    end

    # The agent's grants, each with the role it really carries now:
    # [[grant, role], ...]. Nothing for a disabled agent or membership.
    # ponytail: re-reads the granter's role per call; cache per request if
    # agents get many grants.
    def self.agent_grants(membership)
      agent = Agent.active.find_by(membership_id: membership.id, organization_id: membership.organization_id)
      return [] unless agent && membership.status == Membership::STATUS_ACTIVE

      agent.disk_grants.includes(:node, :granted_by).filter_map do |g|
        granter = g.granted_by
        next unless granter&.status == Membership::STATUS_ACTIVE && !granter.agent?

        cap = role(granter, g.node)
        next if cap.nil?

        r = [g.role, cap].min_by { |x| Disk.role_rank(x) }
        r = Disk::ROLE_MANAGE if r == Disk::ROLE_EDIT && cap == Disk::ROLE_MANAGE && agent.permits?(Agent::DISK_MANAGE)
        [g, r]
      end
    end

    def self.agent_scope(membership)
      seeds = agent_grants(membership).map { |g, _| g.node_id }
      live_shares = Disk::Share.where(organization_id: membership.organization_id).live.select(:id)
      Disk::Node.where(sealed: false) # agent grants are explicit, so a C:\ node (personal workspace) is reachable too
        .where("disk_nodes.id IN (#{Disk::Node.subtree_ids_sql(seeds)})")
        .where("disk_nodes.share_id IS NULL OR disk_nodes.share_id IN (#{live_shares.to_sql})")
    end

    def self.agent_sources(membership, node, path: nil)
      return [] if node.sealed? || node.share&.trashed?

      ids = (path || node.path).map(&:id)
      agent_grants(membership).select { |g, _| ids.include?(g.node_id) }.map do |g, r|
        Source.new(kind: SOURCE_AGENT_GRANT, role: r, node: g.node)
      end
    end
  end
end
