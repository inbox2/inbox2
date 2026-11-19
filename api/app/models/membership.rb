class Membership < ApplicationRecord
  key_prefix "mbr"

  ROLES = %w[owner admin member].freeze
  ADMIN_ROLES = %w[owner admin].freeze
  # Hierarchy for grant-ceiling checks: a higher rank can manage lower ranks.
  ROLE_RANK = { "member" => 1, "admin" => 2, "owner" => 3 }.freeze
  STATUSES = %w[invited active disabled].freeze
  MANAGEABLE_STATUSES = %w[active disabled].freeze

  STATUS_INVITED = "invited".freeze
  STATUS_ACTIVE = "active".freeze
  STATUS_DISABLED = "disabled".freeze
  ROLE_OWNER = "owner".freeze
  ROLE_ADMIN = "admin".freeze
  ROLE_MEMBER = "member".freeze
  TYPE_HUMAN = "human".freeze
  TYPE_AGENT = "agent".freeze

  # Mailbox local-part charset (left of the @). RFC-ish but conservative.
  LOCAL_PART_FORMAT = /\A[a-z0-9](?:[a-z0-9._-]*[a-z0-9])?\z/

  belongs_to :user
  belongs_to :organization
  has_many :mailboxes, dependent: :destroy
  has_many :mail_client_passwords, dependent: :destroy
  has_many :space_memberships, dependent: :destroy
  has_many :spaces, through: :space_memberships
  # Per-domain access grants: which domains' slice of the shared org pool this
  # member may see (when not all_domains). See Conversation.visible_to.
  has_many :membership_domains, dependent: :destroy
  has_many :domains, through: :membership_domains
  # Retired-mailbox reroutes pointing at this membership. Nullify (not destroy)
  # so removing the target degrades the alias to a bounce rather than crashing.
  has_many :inbound_aliases, class_name: "MailboxAlias",
    foreign_key: :target_membership_id, dependent: :nullify

  # Every other table that FK-references a membership is ON DELETE NO ACTION, so
  # destroying a membership (offboarding) needs an explicit dependent rule here
  # or Postgres raises a foreign-key violation. The split is by column nullability:
  #   NOT NULL → destroy the dependent row (it can't outlive the membership)
  #   nullable → nullify, preserving the record (audit/history) without the link.
  has_many :agents, dependent: :destroy
  has_many :conversation_accesses, dependent: :destroy
  has_many :conversation_assignees, dependent: :destroy
  has_many :domain_key_grants, dependent: :destroy
  has_many :note_reactions, dependent: :destroy
  has_many :notes, dependent: :destroy
  has_many :supervised_agents, class_name: "Agent",
    foreign_key: :supervisor_membership_id, dependent: :nullify
  has_many :activity_events, dependent: :nullify
  has_many :audit_logs, dependent: :nullify
  has_many :calendars, dependent: :nullify
  # Meet links this member created; links that BOOK them hang off
  # invitee_membership_id and are queried explicitly where needed.
  has_many :meet_links, dependent: :destroy
  # Links a colleague created that BOOK this member — destroyed with them, or
  # removing a booked member trips the invitee FK.
  has_many :booking_meet_links, class_name: "MeetLink", foreign_key: :invitee_membership_id,
    dependent: :destroy, inverse_of: :invitee_membership
  has_many :blocked_times, dependent: :destroy
  has_many :external_busy_blocks, dependent: :delete_all
  has_many :conferencing_connections, dependent: :destroy
  has_many :signatures, dependent: :nullify
  has_many :templates, dependent: :nullify
  has_many :views, dependent: :nullify
  has_many :created_calendar_events, class_name: "CalendarEvent",
    foreign_key: :created_by_membership_id, dependent: :nullify
  has_many :authored_notifications, class_name: "Notification",
    foreign_key: :actor_membership_id, dependent: :nullify

  # A sealed key holder who leaves freezes their scopes until a rotate
  # (docs/plans/disk-build.md 6.7). Bulk status changes call
  # Disk::KeyGrant.freeze_holders! themselves.
  before_destroy :freeze_disk_keys
  after_update :freeze_disk_keys, if: -> { saved_change_to_status? && status != STATUS_ACTIVE }
  # Each team gets a drive letter in the order the person joined: D:, E:, F: ...
  # (decided 2026-10-07). Stored, so leaving a team never shifts the others.
  before_create :assign_drive_letter

  validates :role, inclusion: { in: ROLES }
  validates :status, inclusion: { in: STATUSES }
  validates :user_id, uniqueness: { scope: :organization_id }
  validate :send_as_on_org_domains

  # Extra From addresses an admin granted this member (info@, sales@ — set on
  # their console page). Full addresses, lowercase.
  normalizes :send_as_addresses, with: ->(list) { Array(list).map { |a| a.to_s.strip.downcase }.reject(&:blank?).uniq }

  # ── Scopes ───────────────────────────────────────────────────────────────
  scope :active,   -> { where(status: STATUS_ACTIVE) }
  scope :invited,  -> { where(status: STATUS_INVITED) }
  scope :disabled, -> { where(status: STATUS_DISABLED) }
  scope :admins,   -> { where(role: ADMIN_ROLES) }
  scope :owners,   -> { where(role: ROLE_OWNER) }
  scope :humans,   -> { where(member_type: TYPE_HUMAN) }

  # ── Invite token ─────────────────────────────────────────────────────────
  # The invite email carries a single-use random token, never the membership
  # key: the key is public to every teammate (Team tab), a token is only ever
  # known to the invitee's mailbox. Stored hashed; the raw value exists only in
  # memory right after minting, for the mail. Cleared on activation.
  attr_accessor :invite_token

  def mint_invite_token!
    raw = SecureRandom.urlsafe_base64(32)
    update!(invite_token_digest: self.class.digest_invite_token(raw))
    self.invite_token = raw
  end

  def self.digest_invite_token(raw) = Digest::SHA256.hexdigest(raw.to_s)

  # The still-pending membership this raw token was minted for, or nil.
  def self.find_by_invite_token(raw)
    return nil if raw.blank?

    invited.find_by(invite_token_digest: digest_invite_token(raw))
  end

  # ── Domain access ────────────────────────────────────────────────────────
  # Whether this member sees the whole org pool. Owners/admins always do; a
  # regular member does only when flagged all_domains (else they're scoped to
  # their granted domains via Conversation.visible_to). A scoped member with
  # ZERO domain grants is a "limited member" (spec 5.1.6): they see only
  # conversations shared with them — assigned, tagged in, or matched by a
  # grant_access visibility rule.
  def all_domains_access? = admin? || all_domains?

  # Domain ids whose pool slice this member may see (every org domain when
  # unscoped). Direct conversation assignments/grants can still expose threads
  # outside these — that override lives in Conversation.visible_to.
  def accessible_domain_ids
    all_domains_access? ? organization.domains.ids : domain_ids
  end

  # The domains this member works on: their pool grants plus wherever they hold
  # a mailbox or a send-as address. Drives which domain tabs they get; pool
  # visibility stays accessible_domain_ids (a rules-only member has no pool).
  def home_domain_ids
    hosts = send_as_addresses.map { |a| a.split("@", 2).last }
    (accessible_domain_ids + mailboxes.map(&:domain_id) + organization.domains.where(name: hosts).ids).uniq
  end

  # The teammates this member may know about: everyone when they see the whole
  # pool, else only the members who work on one of their domains. Every people
  # list a member can reach (/members, mailboxes, scheduling, spaces, E2EE grant
  # directory) goes through this, so a domain-scoped member never learns who is
  # on the org's other teams (2026-11-08 audit, before husttle.com joined).
  def teammates
    scope = organization.memberships.includes(:domains, mailboxes: :domain)
    return scope if all_domains_access?

    mine = home_domain_ids
    scope.where(id: scope.select { |m| (m.home_domain_ids & mine).any? }.map(&:id))
  end

  # Every address this member may send as, for the clients' From pickers — the
  # same answer can_send_as? gives: username@ each pool domain, their mailboxes,
  # and the send-as grants.
  def from_addresses
    username = user.username.to_s.downcase
    hosts = organization.domains.where(id: accessible_domain_ids).pluck(:name)
    (hosts.map { |h| "#{username}@#{h.downcase}" } + email_addresses.map(&:downcase) + send_as_addresses).uniq
      .select { |a| can_send_as?(a) }
  end

  # Every teammate's personal address in this org (their Mailbox rows, plus
  # username@domain on each domain this member sees — can_send_as? lets anyone
  # send under their username without a Mailbox row), lowercase, excluding this
  # member's own — the exclusion set Conversation.visible_to hides.
  def teammate_mailbox_addresses
    mailboxes = teammate_mailbox_addresses_anywhere
    hosts = organization.domains.where(id: accessible_domain_ids).pluck(:name).map(&:downcase)
    usernames = organization.memberships.where.not(id: id).joins(:user).pluck(Arel.sql("LOWER(users.username)"))
    (mailboxes + usernames.product(hosts).map { |u, h| "#{u}@#{h}" }).uniq
  end

  # Disabled by a plan downgrade (over the collaborator seat limit) rather than
  # by an admin — auto-restored when the org upgrades back. See
  # Organization#apply_plan_limits!.
  def billing_locked? = billing_locked_at.present?

  def freeze_disk_keys = Disk::KeyGrant.freeze_holders!(id)

  def send_as_on_org_domains
    hosts = organization&.domains&.pluck(:name)&.map(&:downcase) || []
    bad = send_as_addresses.reject { |a| a.match?(/\A[^@\s]+@[^@\s]+\z/) && hosts.include?(a.split("@", 2).last) }
    errors.add(:send_as_addresses, "must be addresses on this workspace's domains (#{bad.join(', ')})") if bad.any?
    taken = send_as_addresses & teammate_mailbox_addresses_anywhere
    errors.add(:send_as_addresses, "can't include a teammate's own mailbox (#{taken.join(', ')})") if taken.any?
  end

  # Every other member's mailbox address in the org, lowercase — a personal
  # address nobody else may claim, by username or by a send-as grant.
  def teammate_mailbox_addresses_anywhere
    Mailbox.joins(:domain)
      .where(domains: { organization_id: organization_id })
      .where.not(membership_id: id)
      .pluck(Arel.sql("LOWER(mailboxes.local_part || '@' || domains.name)"))
  end

  FIRST_DRIVE_LETTER = "D".freeze

  def assign_drive_letter
    return if drive_letter.present? || agent? || organization&.personal?

    taken = Membership.joins(:organization).merge(Organization.teams).where(user_id: user_id).where.not(drive_letter: nil).pluck(:drive_letter)
    self.drive_letter = (FIRST_DRIVE_LETTER.."Z").find { |l| !taken.include?(l) }
  end

  # ── Disk identity ────────────────────────────────────────────────────────
  # C:\ nodes belong to the person: their custodian is the user's personal
  # workspace membership (User#personal_membership), whichever team they act in.
  def personal_membership_id = agent? ? nil : (@personal_membership_id ||= user.personal_membership.id)
  # This membership and the personal one: what grants, stars and key grants are looked up by.
  def disk_ids = [id, personal_membership_id].compact.uniq
  def custodian_of?(node) = node.custodian_membership_id.present? && node.custodian_membership_id == personal_membership_id
  # The membership that holds this person's role on node: the personal one on their own C:\, else this.
  def as_holder(node) = custodian_of?(node) ? user.personal_membership : self

  # Whether this member may send mail as `address`: their username on an org
  # domain whose pool they see, one of their own mailboxes, or an address an
  # admin granted them (send_as_addresses: info@, sales@). Every outbound path — messages, drafts,
  # calendar invitations — must go through this; without it any member could
  # send as anyone on any of the org's domains (Codex review of 46b82854).
  def can_send_as?(address)
    bare = MailHeaderEncoding.bare_addresses(address.to_s).first&.downcase
    local, host = bare.to_s.split("@", 2)
    domain = host.present? && organization.domains.find_by(name: host)
    return false unless domain
    return true if mailboxes.where(domain: domain).exists?(["LOWER(local_part) = ?", local])
    # A teammate's own mailbox is theirs alone — no username or grant reaches it,
    # even a grant made before the mailbox existed.
    return false if Mailbox.where(domain: domain).where.not(membership_id: id).exists?(["LOWER(local_part) = ?", local])

    send_as_addresses.include?(bare) ||
      (accessible_domain_ids.include?(domain.id) && local == user.username.to_s.downcase)
  end

  # ── Role predicates ──────────────────────────────────────────────────────
  # Owner is treated as admin-or-better everywhere admin rights are required.
  def owner?  = role == ROLE_OWNER
  def admin?  = ADMIN_ROLES.include?(role)
  def member? = role == ROLE_MEMBER
  # The membership an Agent acts through (AgentsController makes one per agent).
  def agent? = member_type == TYPE_AGENT

  # Position in the owner > admin > member hierarchy (0 for unknown roles).
  def rank = ROLE_RANK.fetch(role, 0)

  # Whether this membership may *assign* `target_role` to someone else.
  # Policy: admins can only grant the member role; owners can grant any role.
  # Members can grant nothing.
  def can_grant_role?(target_role)
    return false unless admin?
    return true if owner?
    target_role.to_s == ROLE_MEMBER
  end

  # Every address this member has, across the org's domains (one per Mailbox).
  # Enumerates the `mailboxes` association directly (no `.includes`, which would
  # re-query even when the caller already preloaded `mailboxes: :domain`).
  def email_addresses
    mailboxes.map(&:email_address)
  end

  # A convenience "main" address (a mailbox on the org's default/oldest domain,
  # else any mailbox).
  def primary_email_address
    mbx = mailboxes.min_by { |m| m.domain&.created_at || Time.at(0) }
    mbx&.email_address
  end
end
