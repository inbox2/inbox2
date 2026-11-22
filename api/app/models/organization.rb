class Organization < ApplicationRecord
  key_prefix "org"

  # Rspamd score at/above which inbound mail is filed as spam. Rspamd is the only
  # thing that files to the Spam folder (the LLM triage classifier never does),
  # so this one number carries the whole load. Untrained Bayes rarely clears 7.0
  # on real spam — mails scoring 5–6 on static rules alone were reaching the
  # inbox, hence 5.0.
  DEFAULT_SPAM_THRESHOLD = 5.0
  VIEW_POLICIES = %w[members admins_only].freeze
  VIEW_POLICY_MEMBERS = "members".freeze
  VIEW_POLICY_ADMINS_ONLY = "admins_only".freeze

  # SaaS mailbox-cap presets (the 1 / 5 / unlimited choices). A nil mailbox_limit
  # falls back to the effective plan's collaborator limit.
  MAILBOX_LIMIT_PRESETS = { "single" => 1, "team" => 5, "unlimited" => Plan::UNLIMITED }.freeze

  # Square-icon resolution: a user-uploaded icon wins over the auto-fetched
  # favicon; the client falls back to initials when neither is set.
  ICON_SOURCE_UPLOAD = "upload".freeze
  ICON_SOURCE_FAVICON = "favicon".freeze

  def icon_source
    if icon_url.present?
      ICON_SOURCE_UPLOAD
    elsif favicon_url.present?
      ICON_SOURCE_FAVICON
    end
  end

  def resolved_icon_key
    icon_url.presence || favicon_url.presence
  end

  # owner_id is the *primary* owner / billing contact. The full set of owners is
  # the role:owner memberships (see #owner_memberships). Nullable so an owner can
  # be offboarded after the primary is reassigned.
  belongs_to :owner, class_name: "User", optional: true
  # The person whose C:\ this is: set on the hidden personal workspace org that
  # holds a user's Disk (decided 2026-10-07). nil on every team org.
  belongs_to :personal_user, class_name: "User", optional: true
  belongs_to :agency, optional: true
  # Per-org plan override (SaaS set). When nil, the org inherits its subscription
  # plan (or Free). See #effective_plan.
  belongs_to :plan, optional: true
  has_one :subscription, dependent: :destroy
  has_many :domains, dependent: :destroy
  # Disk rows go before memberships: a C:\ root blocks its custodian's
  # deletion, and the node/share foreign keys cascade or nullify the rest
  # (versions go with their nodes, upload parts with their uploads). Stored
  # objects stay behind for the reconcile job to report.
  has_many :disk_imports, class_name: "Disk::Import", dependent: :delete_all # items cascade
  has_many :disk_import_connections, class_name: "Disk::ImportConnection", dependent: :delete_all
  has_many :disk_uploads, class_name: "Disk::Upload", dependent: :delete_all
  has_many :disk_events, class_name: "Disk::Event", dependent: :delete_all
  has_many :disk_nodes, class_name: "Disk::Node", dependent: :delete_all
  has_many :disk_shares, class_name: "Disk::Share", dependent: :delete_all
  has_many :memberships, dependent: :destroy
  has_many :members, through: :memberships, source: :user
  has_many :mailboxes, through: :memberships
  has_many :tags, dependent: :destroy
  has_many :conversations, dependent: :destroy
  has_many :messages, dependent: :destroy
  has_many :attachments, dependent: :destroy
  has_many :rules, dependent: :destroy
  has_many :notifications, dependent: :destroy
  has_many :views, dependent: :destroy
  has_many :spaces, dependent: :destroy
  has_many :triage_labels, dependent: :destroy
  has_many :webhooks, dependent: :destroy
  # The ESP (docs/ESP.md). Deliveries and events go with their messages.
  has_many :esp_messages, class_name: "Esp::Message", dependent: :destroy
  has_many :esp_deliveries, class_name: "Esp::Delivery"
  has_many :esp_keys, class_name: "Esp::Key", dependent: :destroy
  has_many :esp_domains, class_name: "Esp::Domain", dependent: :destroy
  # Third-party apps allowed to broker provider OAuth through us — docs/App-OAuth.md.
  has_many :oauth_apps, dependent: :destroy
  has_many :audit_logs, dependent: :destroy
  has_many :mail_filters, dependent: :destroy
  has_many :delivery_channels, dependent: :destroy
  has_many :suppression_entries, dependent: :destroy
  has_many :mail_auth_reports, dependent: :destroy
  has_many :mailbox_aliases, dependent: :destroy
  has_many :activity_events, dependent: :destroy
  has_many :signatures, dependent: :destroy
  has_many :templates, dependent: :destroy
  has_many :agents, dependent: :destroy
  has_many :calendars, dependent: :destroy
  # Meet links + their requests (docs/Calendar.md). Blocked times feed FreeBusy.
  has_many :meet_links, dependent: :destroy
  has_many :meeting_requests, dependent: :destroy
  has_many :blocked_times, dependent: :destroy
  has_many :external_busy_blocks, dependent: :delete_all
  has_many :calendar_events, through: :calendars
  has_many :custom_statuses, dependent: :destroy
  # ponytail: an org wipe leaves an unexpired export zip in storage for up to
  # DataExport::RETENTION; purge storage_key here if that ever matters.
  has_many :data_exports, dependent: :delete_all
  has_many :tag_groups, dependent: :destroy
  has_many :contacts, dependent: :destroy
  has_many :custom_roles, dependent: :destroy
  has_many :member_groups, dependent: :destroy
  has_many :integrations, dependent: :destroy
  has_many :widget_configs, dependent: :destroy
  has_one :saml_config, dependent: :destroy
  has_many :saml_identities, dependent: :destroy
  has_one :mailbox_graph_snapshot, dependent: :destroy

  validate :mail_clients_need_a_paid_plan

  validates :name, presence: true
  validates :slug, uniqueness: true, allow_nil: true

  # Team orgs: what people join, pay for and switch between. Personal workspaces
  # exist only to hold a C:\ and never appear in org lists or metrics.
  scope :teams, -> { where(personal_user_id: nil) }

  def personal? = personal_user_id.present?

  # The one way a team org comes to life (web signup and the SaaS operator plane
  # both call it): org + first domain + owner membership + Free subscription +
  # the system tags and default Spaces mail classification relies on. Before
  # this, the SaaS path skipped the last three and such orgs limped along on
  # lazy `ensure_*` calls. Raises RecordInvalid; caller handles the 422.
  def self.provision!(owner:, domain_name:, **attrs)
    transaction do
      org = create!(attrs.merge(owner: owner))
      org.domains.create!(name: domain_name, status: Domain::STATUS_PENDING_DNS)
      org.memberships.create!(user: owner, role: Membership::ROLE_OWNER, status: Membership::STATUS_ACTIVE)
      Subscription.create!(organization: org, plan: Plan.free, status: Subscription::STATUS_ACTIVE)
      Tag.ensure_system_tags(org)
      Space.ensure_default_spaces(org)
      org
    end
  end

  PERSONAL_NAME = "My disk".freeze

  # The user's personal workspace, made on first use, with their one membership.
  def self.personal_for(user)
    find_by(personal_user_id: user.id) || transaction do
      org = create!(name: PERSONAL_NAME, slug: "personal-#{Nanoid.generate(size: 12).downcase}", owner: user, personal_user: user)
      org.memberships.create!(user: user, role: Membership::ROLE_OWNER, status: Membership::STATUS_ACTIVE)
      org
    end
  rescue ActiveRecord::RecordNotUnique
    find_by!(personal_user_id: user.id)
  end

  # The web app's top-level paths (ui/web/src/routes.jsx). An org slug is the
  # first path segment of its URLs, so an org named "Disk" must not take /disk.
  # Domain slugs cannot collide: a domain name has a dot, its slug a hyphen.
  RESERVED_SLUGS = %w[
    accept-invite admin api console disk disk-engine error explorer forgot-password link login mail meet
    no-access notification oauth onboarding reset-password settings setup share signup spaces sso triage-lab
    upgrade waitlist
  ].freeze
  validates :view_creation_policy, inclusion: { in: VIEW_POLICIES }

  before_validation :generate_slug, on: :create

  # ── Domains ─────────────────────────────────────────────────────────────────
  # The org's representative domain: the one used wherever the org must present a
  # single canonical domain — workspace branding (favicon), the default outbound
  # from-address, SAML entity id, and the back-compat `domain`/`status` mirror
  # fields. There is no stored "primary" flag (all domains are equal, first-class,
  # and pool mail identically); this is simply the oldest domain, derived.
  #
  # Resolved from the loaded `domains` collection (not a fresh `find_by`, which
  # would issue SQL on every call even when `domains` is preloaded) and memoized,
  # since the serializer reads it several times per org.
  # The member whose personal address this is: a Mailbox, or username@ an org
  # domain (can_send_as? lets anyone send under their username). Stamped on a
  # new thread as Conversation#personal_membership_id.
  def personal_membership_id_for(address)
    local, host = MailHeaderEncoding.bare_addresses(address.to_s).first.to_s.downcase.split("@", 2)
    local = Mailbox.base_local_part(local)
    return if local.blank? || host.blank? || !domains.exists?(name: host)

    Mailbox.joins(:domain).where(domains: { organization_id: id, name: host }, local_part: local).pick(:membership_id) ||
      memberships.joins(:user).where("LOWER(users.username) = ?", local).pick(:id)
  end

  # A new outbound thread's personal owner: its From's member, else its first
  # To recipient's — the same first-recipient rule inbound mail follows.
  def personal_membership_id_for_thread(from, to)
    personal_membership_id_for(from) || personal_membership_id_for(to)
  end

  def default_domain
    return @default_domain if defined?(@default_domain)

    @default_domain = domains.min_by(&:created_at)
  end

  def domain_names
    domains.pluck(:name)
  end

  # ── Owners (multi) ──────────────────────────────────────────────────────────
  # Every membership with the owner role; owner_id is the primary among these.
  def owner_memberships
    memberships.where(role: Membership::ROLE_OWNER)
  end

  # ── Plan resolution ─────────────────────────────────────────────────────────
  # The plan that governs this org: a SaaS per-org override wins, otherwise the
  # org's subscription plan, otherwise Free.
  def effective_plan
    plan || subscription&.plan || Plan.free
  end
  alias_method :current_plan, :effective_plan

  # Mail clients are open when an admin switched them on AND the plan still
  # includes them: a downgrade to Free closes the door without touching the switch.
  def mail_clients_open? = mail_clients_enabled && effective_plan.mail_clients?

  def on_free_plan?
    effective_plan.free?
  end

  # The Rspamd score at/above which inbound mail is filed as spam: the org's
  # override, else the default. Single source for the ingest spam gate and the
  # AI-triage agreement check.
  def effective_spam_threshold
    spam_threshold || DEFAULT_SPAM_THRESHOLD
  end

  # Server-side AI triage (Jev via TypeSafe + the OpenAI summary) is paid, so
  # it's a paid-plan feature only. Mirrors the spam_filter plan gate.
  def ai_triage_enabled?
    effective_plan.ai_triage
  end

  # Team-activity insights switch (owner/admin toggle). Defensive read: if the
  # column isn't on this DB yet (schema.rb edited but the live DB not yet
  # altered), default to ON rather than raising MissingAttribute on every
  # org serialize.
  def activity_tracking_enabled?
    !has_attribute?(:activity_tracking_enabled) || self[:activity_tracking_enabled] != false
  end

  # E2EE message sealing entitlement (docs/E2EE.md) — the plan gate. Whether a
  # given domain actually seals is the per-domain switch + `E2ee.effective?`.
  def e2ee_entitled?
    return personal_user.accessible_organizations.any?(&:e2ee_entitled?) if personal?

    effective_plan.e2ee
  end

  # Disk (docs/plans/disk-build.md): the plan gate and the pooled quota, the
  # plan's GB per active human member unless SaaS ops set an override.
  def disk_enabled?
    personal? || effective_plan.disk?
  end

  # The downgrade lifecycle (spec F8): from disk_lost_at, read-only for
  # DISK_READ_ONLY_DAYS, then blocked until DISK_PURGE_DAYS, then purged by
  # Disk::LifecycleJob. :none for an org that never had Disk. Marks the loss
  # the first time it is noticed (a plan change, wherever it happened) and
  # clears it once the plan includes Disk again.
  DISK_READ_ONLY_DAYS = 30
  DISK_PURGE_DAYS = 90
  DISK_ACTIVE = :active
  DISK_READ_ONLY = :read_only
  DISK_BLOCKED = :blocked
  DISK_NONE = :none

  def disk_state(now: Time.current)
    if disk_enabled?
      update_columns(disk_lost_at: nil) if disk_lost_at
      return DISK_ACTIVE
    end
    lost = disk_lost_at || mark_disk_lost!(now)
    return DISK_NONE unless lost
    return DISK_READ_ONLY if lost > now - DISK_READ_ONLY_DAYS.days

    DISK_BLOCKED
  end

  def disk_readable? = [DISK_ACTIVE, DISK_READ_ONLY].include?(disk_state)
  def disk_writable? = disk_state == DISK_ACTIVE

  # Sets disk_lost_at when this org has Disk data but its plan no longer
  # includes Disk, and tells the owners once. Returns the time, or nil.
  def mark_disk_lost!(now = Time.current)
    return nil unless Disk::Node.where(organization_id: id).exists?

    won = self.class.where(id: id, disk_lost_at: nil).update_all(disk_lost_at: now) == 1
    reload
    Disk::Lifecycle.notify_owners(self, 0) if won
    disk_lost_at
  end

  def disk_quota_bytes
    gb = disk_quota_override_gb ||
      if personal?
        # A personal allowance: one member's share from the best tier among the person's teams.
        personal_user.accessible_organizations.map { |o| o.effective_plan.disk_gb_per_member }.max || 0
      else
        effective_plan.disk_gb_per_member * memberships.where(status: Membership::STATUS_ACTIVE,
                                                               member_type: Membership::TYPE_HUMAN).count
      end
    gb.gigabytes
  end

  def effective_mail_size_limit
    effective_plan.max_message_size_mb * 1_048_576 # bytes
  end

  # Domains-per-org quota (Free = 1). Reached when adding another would exceed it.
  def domain_limit_reached?
    domains.count >= effective_plan.max_domains
  end

  # ── Collaborator cap ────────────────────────────────────────────────────────
  # "Collaborators" = active members ON TOP OF the owner(s) (non-owner seats).
  # Enforced on every plan (Free 0 / Startup 2 / Serial unlimited).
  # The collaborator cap counts every active member except one free seat: the
  # primary owner (owner_id), or the oldest active owner when there is no
  # primary. Further owners count like any member (Waseem, 2026-11-17). A
  # pending invite holds its seat, so accepting can never go over the cap.
  def free_seat_membership
    active = memberships.active
    active.owners.find_by(user_id: owner_id) || active.owners.order(:created_at).first
  end

  def counted_memberships
    seats = memberships.where(status: [Membership::STATUS_ACTIVE, Membership::STATUS_INVITED])
    free = free_seat_membership
    free ? seats.where.not(id: free.id) : seats
  end

  def collaborator_count
    counted_memberships.count
  end

  # Over the cap after a membership change? True when the change added a
  # counted seat (a re-enabled member, a role change that moves the free seat)
  # and the org is now past its plan's limit. Callers measure `before` and
  # apply the change under a lock on the org.
  def seats_exceeded_since?(before)
    after = collaborator_count
    after > before && after > effective_plan.max_collaborators
  end

  def collaborator_limit_reached?
    collaborator_count >= effective_plan.max_collaborators
  end

  # ── Plan limit reconciliation (downgrade) ───────────────────────────────────
  # How far over `plan`'s limits the org currently is.
  def downgrade_impact(plan)
    {
      domains_over: [domains.count - plan.max_domains, 0].max,
      collaborators_over: [collaborator_count - plan.max_collaborators, 0].max
    }
  end

  def over_plan_limits?(plan)
    i = downgrade_impact(plan)
    i[:domains_over].positive? || i[:collaborators_over].positive?
  end

  # Reconcile resources to `plan` after a plan change. Domains: lock the newest
  # beyond the limit (primary always kept), unlock the kept ones. Collaborators:
  # on a downgrade disable the newest counted seats over the limit (other owners
  # last) and tag them billing-locked; on an upgrade restore previously
  # billing-locked seats up to the new limit (manually-disabled members are
  # never auto-restored).
  def apply_plan_limits!(plan)
    ordered = domains.order(created_at: :asc).to_a
    keep = ordered.first(plan.max_domains)
    lock = ordered - keep
    Domain.where(id: keep.map(&:id)).where.not(locked_at: nil).update_all(locked_at: nil)
    Domain.where(id: lock.map(&:id)).update_all(locked_at: Time.current) if lock.any?

    limit = plan.max_collaborators
    # Seats are kept active before invited, owners before other members,
    # oldest first. Over the limit, an active seat is disabled and
    # billing-locked; a pending invite is withdrawn (destroyed, as members#destroy
    # does), since restoring one later would skip its acceptance.
    seats = counted_memberships.order(created_at: :asc).to_a.each_with_index
      .sort_by { |m, i| [m.status == Membership::STATUS_ACTIVE ? 0 : 1, m.owner? ? 0 : 1, i] }
      .map(&:first)

    if seats.size > limit
      invites, excess = seats.drop(limit).partition { |m| m.status == Membership::STATUS_INVITED }
      Membership.transaction do
        invites.each(&:destroy!)
        if excess.any?
          Membership.where(id: excess.map(&:id))
            .update_all(status: Membership::STATUS_DISABLED, billing_locked_at: Time.current, updated_at: Time.current)
          Disk::KeyGrant.freeze_holders!(excess.map(&:id))
        end
      end
      excess.each { |m| SessionRevoker.revoke_user!(m.user) }
    else
      # Headroom freed (upgrade) — restore billing-locked seats, oldest first,
      # into the seats pending invites have not already taken.
      slots = limit - seats.size
      return if slots <= 0

      restore = memberships.where(status: Membership::STATUS_DISABLED)
        .where.not(billing_locked_at: nil)
        .order(created_at: :asc).first(slots)
      return if restore.empty?

      Membership.where(id: restore.map(&:id))
        .update_all(status: Membership::STATUS_ACTIVE, billing_locked_at: nil, updated_at: Time.current)
    end
  end

  def billing_past_due?
    subscription&.status == Subscription::STATUS_PAST_DUE
  end

  def in_grace_period?
    billing_past_due? && subscription.current_period_ends_at&.future?
  end

  # ── Mailbox cap ─────────────────────────────────────────────────────────────
  # A "mailbox" is an address (Mailbox row across the org's domains).
  def mailbox_count
    mailboxes.count
  end

  # Mailboxes (addresses) are capped only by an explicit SaaS override; the plan
  # caps collaborators (members), not addresses.
  def effective_mailbox_limit
    mailbox_limit || Plan::UNLIMITED
  end

  def mailbox_limit_reached?
    mailbox_count >= effective_mailbox_limit
  end

  # True only when an explicit SaaS override exists and is hit.
  def mailbox_override_reached?
    mailbox_limit.present? && mailbox_count >= mailbox_limit
  end

  # ── Operational suspension ──────────────────────────────────────────────────
  def suspended?
    suspended_at.present?
  end

  def suspend!(reason = nil)
    update!(suspended_at: Time.current, suspended_reason: reason.presence)
  end

  def unsuspend!
    update!(suspended_at: nil, suspended_reason: nil)
  end

  private

  def generate_slug
    return if slug.present? || name.blank?

    base = name.parameterize
    candidate = base
    counter = 1
    while RESERVED_SLUGS.include?(candidate) || Organization.exists?(slug: candidate)
      candidate = "#{base}-#{counter}"
      counter += 1
    end
    self.slug = candidate
  end

  # Only checked when the switch is being turned on, so a later downgrade never
  # breaks unrelated saves (Organization#mail_clients_open? closes the door then).
  def mail_clients_need_a_paid_plan
    return unless mail_clients_enabled && mail_clients_enabled_changed? && !effective_plan.mail_clients?

    errors.add(:mail_clients_enabled, "needs a paid plan")
  end
end
