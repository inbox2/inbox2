module Disk
  # Activity. `detail` never carries a sealed node's name.
  class Event < ApplicationRecord
    key_prefix "dev"

    ACTIONS = %w[
      created renamed moved copied trashed restored purged uploaded version_added version_restored
      share_created share_updated share_trashed share_restored
      member_added member_changed member_removed granted grant_changed ungranted
      link_created link_revoked link_used page_saved page_restored agent_granted agent_ungranted
      preview_failed reassigned sealed_abandoned saved_from_mail key_rotated key_transferred switched
    ].freeze
    ACTIONS.each { |a| const_set("ACTION_#{a.upcase}", a) }

    belongs_to :organization
    belongs_to :node, class_name: "Disk::Node", optional: true
    belongs_to :share, class_name: "Disk::Share", optional: true
    belongs_to :actor, class_name: "Membership", foreign_key: :actor_membership_id, optional: true
    belongs_to :link, class_name: "Disk::Link", optional: true
    belongs_to :actor_agent, class_name: "Agent", optional: true

    validates :action, inclusion: { in: ACTIONS }

    # A visitor through a public link has no membership: pass link: instead of an actor.
    # An agent acts through its membership; the event names the agent too.
    def self.record!(action, actor:, node: nil, share: nil, link: nil, **detail)
      detail = detail.except(:name, :from, :to) if node&.sealed?
      agent = actor&.agent? ? actor.agents.first : nil
      create!(organization_id: (node || share).organization_id, action: action, actor: actor, link: link,
              node: node, share: share || node&.share, detail: detail, actor_agent: agent)
    end
  end
end
