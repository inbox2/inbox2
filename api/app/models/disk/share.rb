module Disk
  # A share on D:\. Its files hang off root_node, a parentless folder node.
  class Share < ApplicationRecord
    key_prefix "dsh"

    OPENNESS_ORG = "org".freeze
    OPENNESS_ASSIGNED = "assigned".freeze
    OPENNESS = [OPENNESS_ORG, OPENNESS_ASSIGNED].freeze
    # An open share hands every member this role; manage is never handed out wholesale.
    ORG_ROLES = [Disk::ROLE_VIEW, Disk::ROLE_EDIT].freeze

    # The share emblems the web draws (ui/web/src/components/FileTypeIcon/glyphs.jsx
    # EMBLEMS, less the folder-only shared and sealed). No emblem is nil.
    ICONS = %w[marketing sales finance hr product design support business analytics procurement legal
               engineering].freeze

    TRASH_DAYS = Disk::TRASH_DAYS

    # First-run templates (spec F3): name, emblem and its colour from the mockup.
    TEMPLATES = [
      { name: "Marketing", icon: "marketing", color: "#e06a3d" },
      { name: "Sales", icon: "sales", color: "#2e8f5b" },
      { name: "Finance", icon: "finance", color: "#c98a1b" },
      { name: "HR", icon: "hr", color: "#8a5bd6" },
      { name: "Product", icon: "product", color: "#2f7ad6" },
      { name: "Design", icon: "design", color: "#c2408f" },
      { name: "Support", icon: "support", color: "#1f9aa5" }
    ].freeze

    belongs_to :organization
    # The team the share belongs to (2026-10-04): one payer, several distinct companies,
    # one per domain. Open to the org then means open to members who see this domain.
    # nil: the whole organization.
    belongs_to :domain, optional: true
    belongs_to :root_node, class_name: "Disk::Node", optional: true
    belongs_to :trashed_by, class_name: "Membership", foreign_key: :trashed_by_membership_id, optional: true
    has_many :share_memberships, class_name: "Disk::ShareMembership", dependent: :delete_all
    has_many :nodes, class_name: "Disk::Node"

    validates :name, presence: true, length: { maximum: 120 }
    validates :openness, inclusion: { in: OPENNESS }
    validates :org_role, inclusion: { in: ORG_ROLES }
    validates :icon, inclusion: { in: ICONS }, allow_nil: true
    validates :color, format: { with: /\A#\h{6}\z/ }, allow_nil: true
    validate { errors.add(:domain, "is not one of this organization's domains") if domain && domain.organization_id != organization_id }

    scope :live, -> { where(trashed_at: nil) }

    # "folder" was the plain-folder emblem before the set matched the web's; it means none.
    before_validation { self.icon = nil if icon == "folder" }
    # The slug in Disk URLs follows the name, unique among the org's live shares.
    before_validation :assign_slug, if: -> { slug.blank? || name_changed? || (trashed_at_changed? && trashed_at.nil?) }

    # A share by public id or slug, within `scope`.
    def self.find_by_ref!(scope, ref)
      ref = ref.to_s
      scope.find_by(key: ref) || scope.where(trashed_at: nil).find_by!(slug: ref)
    end

    def open_to_org? = openness == OPENNESS_ORG
    # Open to this member: open to the org and, when the share has a team, the member sees that domain.
    # A whole-org share (no team) is the team's: not for a mailbox-only member.
    def open_to?(membership) = open_to_org? && (domain_id.nil? ? membership.org_wide_access? : membership.accessible_domain_ids.include?(domain_id))
    def trashed? = trashed_at.present?
    def archived? = archived_at.present?

    # A removed domain's shares join the whole org as members-only shares, so
    # nobody gains access; a name that clashes there gets the domain appended,
    # then a number until it is free.
    def self.release_domain!(domain)
      taken = where(organization_id: domain.organization_id, domain_id: nil, trashed_at: nil).pluck(:name).map(&:downcase)
      where(domain_id: domain.id).find_each do |share|
        name = share.name
        unless share.trashed?
          base = "#{share.name} (#{domain.name})".first(120)
          n = 1
          while taken.include?(name.downcase)
            name = n == 1 ? base : "#{base.first(115)} #{n}"
            n += 1
          end
          taken << name.downcase
        end
        share.update_columns(domain_id: nil, openness: OPENNESS_ASSIGNED, name: name)
      end
    end

    # Creates the share and its root folder together.
    def self.create_with_root!(organization:, **attrs)
      transaction do
        share = create!(organization: organization, **attrs)
        root = Disk::Node.create!(organization: organization, share: share, kind: Disk::Node::KIND_FOLDER)
        share.update!(root_node: root)
        share
      end
    end

    # Deletes the share, its nodes and every version: the bytes go back to the
    # quota and the objects leave the bucket once the rows are gone.
    def purge!
      transaction do
        nodes = Disk::Node.where(share_id: id)
        Disk::Version.release!(Disk::Version.where(node_id: nodes.select(:id)))
        Disk::Link.where(node_id: nodes.select(:id)).delete_all # see NodeOps.purge!
        nodes.delete_all
        destroy!
      end
    end

    private

    def assign_slug
      base = name.to_s.parameterize.presence || "share"
      taken = Disk::Share.where(organization_id: organization_id, trashed_at: nil).where.not(id: id).pluck(:slug)
      candidate = base
      n = 1
      candidate = "#{base}-#{n += 1}" while taken.include?(candidate)
      self.slug = candidate
    end
  end
end
