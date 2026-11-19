# Pushleft App admin, protocol version 1: the operator back office of this
# installation, called by the Pushleft console on behalf of a signed-in person
# (docs/SaaS.md). Every write goes through the models, services and jobs that
# /api/v1/saas calls, and lands in the same SaasAuditLog.
#
# Off unless PUSHLEFT_ADMIN_JWKS (a JSON Web Key Set, public keys only) and
# PUSHLEFT_ADMIN_AUDIENCE are set: without them every path under the prefix
# answers 404, which is what a self-hosted install without Pushleft gets. With
# them, every request must carry a token that was signed for that one request
# (see #verified_claims). The app holds no secret.
#
# Deliberately not an ApplicationController: no session, cookie, API key or
# organization applies here, and the lists run across every tenant on purpose
# (this is the operator plane). The JSON shapes are the protocol's, so the Alba
# serializers and ErrorSerializer of the app's own API are not used. Ids are
# the public keys (usr_..., org_...), never a database id.
class PushleftAdminController < ActionController::API
  class Refusal < StandardError
    attr_reader :status, :code, :fields

    def initialize(status, code, message, fields = nil)
      super(message)
      @status, @code, @fields = status, code, fields
    end
  end

  ISSUER = "https://api.pushleft.dev".freeze
  LIST_PARAMS = %w[q view filter sort limit after].freeze
  INVALID = "Some values are not valid".freeze

  NAME = ->(user) { user.display_name.presence || user.username }
  REF = ->(record, label = record&.name) { { id: record.key, label: label } if record }
  TEAM_MEMBERSHIPS = ->(user) { user.memberships.reject { |m| m.organization.personal? } }
  USER_SEARCH = lambda do |scope, like|
    scope.where("username ILIKE :q OR display_name ILIKE :q OR billing_email ILIKE :q", q: like)
  end
  # Personal workspaces hold a C:\ and nothing else: they are in no list here.
  IN_TEAMS = ->(model) { model.where(organization_id: Organization.teams.select(:id)) }

  ROLE_OPTIONS = Membership::ROLES.map { |role| { value: role, label: role.humanize } }.freeze
  MEMBER_STATUS_OPTIONS = [ { value: Membership::STATUS_INVITED, label: "Invited", tone: "warn" },
                            { value: Membership::STATUS_ACTIVE, label: "Active", tone: "good" },
                            { value: Membership::STATUS_DISABLED, label: "Disabled", tone: "bad" } ].freeze
  ACTIVE, SUSPENDED = "active", "suspended"

  # What happens to a departing member's mail and address (UserOffboarder).
  OFFBOARD_INPUT = [
    { name: "data_handling", type: "enum", label: "Mail", required: true, default: UserOffboarder::ARCHIVE,
      options: [ { value: UserOffboarder::ARCHIVE, label: "Keep" },
                 { value: UserOffboarder::WIPE, label: "Delete", tone: "bad" } ],
      help: "Delete removes every message sent to or from this person's addresses." },
    { name: "alias_handling", type: "enum", label: "Old address", required: true,
      default: MailboxAlias::MODE_BOUNCE,
      options: [ { value: MailboxAlias::MODE_BOUNCE, label: "Bounce new mail" },
                 { value: MailboxAlias::MODE_REROUTE, label: "Deliver to a colleague" } ] },
    { name: "reroute_target", type: "ref", resource: "memberships", label: "Colleague",
      help: "Pick an active member of the same organization." }
  ].freeze

  # What /schema publishes of a resource, a field and an action. Every other key
  # in RESOURCES (model, scopes, readers) stays inside the app.
  RESOURCE_KEYS = %i[name label singular kind can search children].freeze
  FIELD_KEYS = %i[name type label help required default list filter sort create update is group
                  min max max_length unit options resource].freeze
  ACTION_KEYS = %i[name label on confirm danger].freeze

  # The whole surface, declared once. Lists filter and sort only on what is
  # marked here, and writes touch only fields marked `update`.
  # Internal keys: `scope` (the rows of the list, when not every row of the
  # model), `column` (when it differs from the name), `read` (a computed
  # value), `count` (a number per record, counted for a whole page in one
  # query), `where` (a filter that is not a plain column match), `available`
  # (whether an action applies to an item now).
  RESOURCES = [
    {
      name: "users", label: "Users", singular: "User", kind: "user",
      can: %w[list show], search: true,
      model: User, preload: { memberships: :organization }, default_sort: "-last_sign_in_at",
      search_scope: USER_SEARCH,
      views: [
        { name: "signed_in_24h", label: "Signed in, last 24 hours",
          scope: ->(s) { s.where(last_sign_in_at: 24.hours.ago..) } }
      ],
      children: [ { resource: "memberships", field: "user" } ],
      fields: [
        { name: "name", type: "string", is: "title", read: NAME },
        { name: "email", type: "email", is: "subtitle", sort: true, column: "billing_email" },
        { name: "username", type: "string", sort: true },
        # ponytail: only an avatar that is an https URL already. An uploaded one
        # is a storage key behind a signed link (UserSerializer.avatar_url) that
        # differs on every call, which would make the polled list change every
        # 5 seconds. Sign it with a day-stable expiry if operators miss the faces.
        { name: "avatar", type: "image", is: "avatar",
          read: ->(u) { u.avatar_url if u.avatar_url.to_s.start_with?("https://") } },
        { name: "organizations", type: "list", list: true,
          read: ->(u) { TEAM_MEMBERSHIPS.call(u).map { |m| m.organization.name }.sort } },
        { name: "role", type: "enum", list: true, options: ROLE_OPTIONS,
          help: "The highest role across this person's organizations.",
          read: ->(u) { TEAM_MEMBERSHIPS.call(u).map(&:role).max_by { |role| Membership::ROLE_RANK[role] } } },
        { name: "status", type: "enum", is: "status", list: true, options: MEMBER_STATUS_OPTIONS,
          help: "Active in at least one organization.",
          read: lambda do |u|
            [ Membership::STATUS_ACTIVE, Membership::STATUS_DISABLED, Membership::STATUS_INVITED ]
              .find { |status| u.memberships.any? { |m| m.status == status } }
          end },
        { name: "last_sign_in_at", type: "datetime", label: "Last sign-in", is: "last_seen", list: true,
          sort: true, filter: true },
        { name: "created_at", type: "datetime", label: "Created", list: true, sort: true, filter: true }
      ],
      actions: [
        { name: "reset_password", label: "Reset password", on: "item",
          confirm: "Mails this person a reset link.",
          available: ->(u) { u.billing_email.present? } },
        { name: "disable", label: "Disable", on: "item",
          confirm: "Blocks this person in every organization and signs them out.",
          available: ->(u) { u.memberships.any? { |m| m.status != Membership::STATUS_DISABLED } } },
        { name: "enable", label: "Enable", on: "item",
          available: ->(u) { u.memberships.any? { |m| m.status == Membership::STATUS_DISABLED } } },
        { name: "offboard", label: "Offboard", on: "item", danger: true,
          confirm: "Removes this person from every organization for good and signs them out.",
          input: OFFBOARD_INPUT, available: ->(u) { u.memberships.any? } }
      ]
    },
    {
      name: "organizations", label: "Organizations", singular: "Organization", kind: "tenant",
      can: %w[list show update], search: true,
      model: Organization, scope: -> { Organization.teams },
      preload: [ :owner, :domains, :plan, { subscription: :plan } ], default_sort: "-created_at",
      search_scope: lambda do |scope, like|
        scope.where("organizations.name ILIKE :q OR organizations.slug ILIKE :q", q: like)
             .or(scope.where(id: Domain.where("name ILIKE ?", like).select(:organization_id)))
      end,
      views: [ { name: SUSPENDED, label: "Suspended", scope: ->(s) { s.where.not(suspended_at: nil) } } ],
      children: [ { resource: "memberships", field: "organization" },
                  { resource: "domains", field: "organization" } ],
      fields: [
        { name: "name", type: "string", is: "title", required: true, max_length: 255, sort: true, update: true },
        { name: "domain", type: "string", is: "subtitle", read: ->(o) { o.default_domain&.name } },
        { name: "status", type: "enum", is: "status", list: true, filter: true,
          options: [ { value: ACTIVE, label: "Active", tone: "good" },
                     { value: SUSPENDED, label: "Suspended", tone: "bad" } ],
          read: ->(o) { o.suspended? ? SUSPENDED : ACTIVE },
          where: lambda do |scope, statuses|
            next scope if statuses.uniq.size > 1
            statuses.first == SUSPENDED ? scope.where.not(suspended_at: nil) : scope.where(suspended_at: nil)
          end },
        { name: "suspended_reason", type: "string", label: "Suspension reason" },
        { name: "suspended_at", type: "datetime", label: "Suspended" },
        { name: "plan", type: "ref", resource: "plans", list: true, read: ->(o) { REF.call(o.effective_plan) } },
        { name: "plan_override", type: "ref", resource: "plans", read: ->(o) { REF.call(o.plan) },
          help: "Change it with Set plan." },
        { name: "owner", type: "ref", resource: "users", read: ->(o) { REF.call(o.owner, o.owner && NAME.call(o.owner)) } },
        { name: "member_count", type: "integer", label: "Members", list: true,
          count: ->(ids) { Membership.where(organization_id: ids).group(:organization_id).count } },
        { name: "mailbox_limit", type: "integer", min: 0, max: Plan::UNLIMITED, update: true,
          help: "Leave empty for no limit." },
        { name: "disk_quota_gb", type: "integer", label: "Disk quota", unit: "GB", min: 0, max: 1_000_000,
          update: true, column: "disk_quota_override_gb", help: "Leave empty to use the quota of the plan." },
        { name: "mailbox_count", type: "integer", label: "Mailboxes", group: "Usage",
          count: lambda do |ids|
            Mailbox.joins(:membership).where(memberships: { organization_id: ids })
                   .group("memberships.organization_id").count
          end },
        # ponytail: the four counts below run for every page of the list, each on
        # its organization_id index. Keep counters per organization if a page
        # gets slow.
        { name: "conversation_count", type: "integer", label: "Conversations", group: "Usage",
          count: ->(ids) { Conversation.where(organization_id: ids).group(:organization_id).count } },
        { name: "message_count", type: "integer", label: "Messages", group: "Usage",
          count: ->(ids) { Message.where(organization_id: ids).group(:organization_id).count } },
        { name: "attachment_count", type: "integer", label: "Attachments", group: "Usage",
          count: ->(ids) { Attachment.where(organization_id: ids).group(:organization_id).count } },
        { name: "storage_bytes", type: "integer", label: "Attachment storage", unit: "bytes", group: "Usage",
          count: ->(ids) { Attachment.where(organization_id: ids).group(:organization_id).sum(:size_bytes) } },
        { name: "disk_bytes_used", type: "integer", label: "Disk used", unit: "bytes", group: "Usage" },
        { name: "created_at", type: "datetime", label: "Created", list: true, sort: true, filter: true }
      ],
      actions: [
        { name: "suspend", label: "Suspend", on: "item",
          input: [ { name: "reason", type: "string", max_length: 500 } ],
          available: ->(o) { !o.suspended? } },
        { name: "unsuspend", label: "Unsuspend", on: "item", available: ->(o) { o.suspended? } },
        { name: "set_plan", label: "Set plan", on: "item",
          input: [ { name: "plan", type: "ref", resource: "plans",
                     help: "Leave empty to follow the subscription." } ] },
        { name: "wipe", label: "Wipe", on: "item", danger: true,
          confirm: "Deletes this organization with its mail, files and members for good." }
      ]
    },
    {
      name: "memberships", label: "Memberships", singular: "Membership",
      can: %w[list show], search: true,
      model: Membership, scope: -> { IN_TEAMS.call(Membership) },
      preload: [ :user, :organization, { mailboxes: :domain } ], default_sort: "-created_at",
      search_scope: ->(scope, like) { scope.where(user_id: USER_SEARCH.call(User.all, like).select(:id)) },
      views: [],
      fields: [
        { name: "name", type: "string", is: "title", read: ->(m) { NAME.call(m.user) } },
        { name: "email", type: "email", is: "subtitle", read: ->(m) { m.user.billing_email } },
        { name: "user", type: "ref", resource: "users", filter: true, column: "user_id",
          read: ->(m) { REF.call(m.user, NAME.call(m.user)) } },
        { name: "organization", type: "ref", resource: "organizations", list: true, filter: true,
          column: "organization_id", read: ->(m) { REF.call(m.organization) } },
        { name: "role", type: "enum", list: true, filter: true, options: ROLE_OPTIONS },
        { name: "status", type: "enum", is: "status", list: true, filter: true, options: MEMBER_STATUS_OPTIONS },
        { name: "addresses", type: "list", list: true, read: ->(m) { m.email_addresses.sort } },
        { name: "created_at", type: "datetime", label: "Created", list: true, sort: true }
      ],
      actions: [
        { name: "remove", label: "Remove", on: "item", danger: true,
          confirm: "Removes this person from the organization for good and signs them out.",
          input: OFFBOARD_INPUT }
      ]
    },
    {
      name: "domains", label: "Domains", singular: "Domain",
      can: %w[list show], search: true,
      model: Domain, scope: -> { IN_TEAMS.call(Domain) }, preload: :organization, default_sort: "-created_at",
      search_scope: ->(scope, like) { scope.where("domains.name ILIKE ?", like) },
      views: [],
      fields: [
        { name: "name", type: "string", is: "title", sort: true },
        { name: "organization", type: "ref", resource: "organizations", list: true, filter: true,
          column: "organization_id", read: ->(d) { REF.call(d.organization) } },
        { name: "status", type: "enum", is: "status", list: true, filter: true,
          options: [ { value: Domain::STATUS_PENDING_DNS, label: "Waiting for DNS", tone: "warn" },
                     { value: Domain::STATUS_VERIFIED, label: "Verified", tone: "good" },
                     { value: Domain::STATUS_RECEIVING_MAIL, label: "Receiving mail", tone: "good" },
                     { value: Domain::STATUS_ERROR, label: "Error", tone: "bad" } ] },
        { name: "created_at", type: "datetime", label: "Created", list: true, sort: true }
      ],
      actions: []
    },
    {
      name: "plans", label: "Plans", singular: "Plan",
      can: %w[list show], search: true,
      model: Plan, default_sort: "price",
      search_scope: ->(scope, like) { scope.where("plans.name ILIKE ?", like) },
      views: [],
      fields: [
        { name: "name", type: "string", is: "title", sort: true },
        { name: "tier", type: "enum", list: true,
          options: Plan::TIERS.map { |tier| { value: tier, label: tier.humanize } } },
        { name: "price", type: "decimal", list: true, sort: true, column: "price_cents",
          read: ->(p) { format("%.2f", p.price_cents / 100.0) } },
        { name: "interval", type: "string", label: "Billing period", list: true },
        { name: "max_domains", type: "integer", label: "Domain limit", help: "Empty means no limit.",
          read: ->(p) { p.max_domains unless p.unlimited_domains? } },
        { name: "max_collaborators", type: "integer", label: "Collaborator limit", help: "Empty means no limit.",
          read: ->(p) { p.max_collaborators unless p.unlimited_collaborators? } },
        { name: "max_message_size_mb", type: "integer", label: "Message size limit", unit: "MB" },
        { name: "spam_filter", type: "boolean" },
        { name: "ai_triage", type: "boolean", label: "AI triage" },
        { name: "e2ee", type: "boolean", label: "End-to-end encryption" }
      ],
      actions: []
    },
    {
      name: "waitlist", label: "Waitlist", singular: "Sign-up",
      can: %w[list show], search: true,
      model: WaitlistSignup, preload: :user, default_sort: "-created_at",
      search_scope: ->(scope, like) { scope.where("name ILIKE :q OR email ILIKE :q OR company ILIKE :q", q: like) },
      views: WaitlistSignup::STATUSES.map do |status|
        { name: status, label: status.humanize, scope: ->(s) { s.where(status: status) } }
      end,
      fields: [
        { name: "name", type: "string", is: "title", sort: true },
        { name: "email", type: "email", is: "subtitle", sort: true },
        { name: "company", type: "string", list: true },
        { name: "industry", type: "string", read: ->(s) { s.industry_label } },
        { name: "industry_note", type: "text" },
        { name: "status", type: "enum", is: "status", list: true, filter: true,
          options: [ { value: WaitlistSignup::STATUS_PENDING, label: "Pending", tone: "warn" },
                     { value: WaitlistSignup::STATUS_INVITED, label: "Invited" },
                     { value: WaitlistSignup::STATUS_REGISTERED, label: "Registered", tone: "good" } ] },
        { name: "invited_at", type: "datetime", label: "Invited", list: true, sort: true },
        { name: "invited_by", type: "string" },
        { name: "registered_at", type: "datetime", label: "Registered" },
        { name: "user", type: "ref", resource: "users", label: "Account",
          read: ->(s) { REF.call(s.user, s.user && NAME.call(s.user)) } },
        { name: "email_services", type: "json", label: "Mail services" },
        { name: "social_accounts", type: "json" },
        { name: "created_at", type: "datetime", label: "Signed up", list: true, sort: true, filter: true }
      ],
      actions: [
        { name: "invite", label: "Invite", on: "item",
          confirm: "Mails a single-use link to create an account. An earlier link stops working.",
          available: ->(s) { s.status != WaitlistSignup::STATUS_REGISTERED } }
      ]
    }
  ].freeze

  before_action :authenticate

  rescue_from(Refusal) { |e| render_error(e.status, e.code, e.message, e.fields) }
  rescue_from(ActiveRecord::RecordNotFound) { render_error(404, "not_found", "Not found") }
  rescue_from(ActiveRecord::RecordNotDestroyed, ActiveRecord::InvalidForeignKey) do
    render_error(409, "conflict", "This record is still in use and cannot be deleted")
  end
  rescue_from(ActiveRecord::RecordInvalid) do |e|
    render_error(422, "invalid", e.record.errors.full_messages.to_sentence,
                 e.record.errors.to_hash.to_h { |attribute, messages| [ attribute.to_s, messages.first ] })
  end

  def process_action(*)
    super
  rescue ActionController::BadRequest
    # Rails parses the query string for its request log before any callback
    # runs, so a malformed one surfaces here, outside rescue_from. It still gets
    # an answer only with a valid token. (The body is parsed in #body_object.)
    authenticate
    render_error(400, "bad_request", "The request could not be parsed") unless performed?
  ensure
    # Every write, the refused ones included. A write that went through also
    # has its SaasAuditLog row (#audit!).
    if @claims && !request.get? && !request.head?
      Rails.logger.info("[PushleftAdmin] write sub=#{@claims['sub'].inspect} role=#{@claims['role'].inspect} " \
                        "jti=#{@claims['jti'].inspect} #{request.request_method} #{request_target} " \
                        "status=#{performed? ? response.status : 500}")
    end
  end

  def schema
    render json: {
      protocol: 1, title: "inbox2", overview: true,
      resources: RESOURCES.map do |res|
        res.slice(*RESOURCE_KEYS).merge(
          views: res[:views].map { |view| view.slice(:name, :label) },
          fields: res[:fields].map { |field| field.slice(*FIELD_KEYS) },
          actions: res[:actions].map do |action|
            action.slice(*ACTION_KEYS).merge(input: action[:input]&.map { |field| field.slice(*FIELD_KEYS) }).compact
          end
        )
      end
    }
  end

  # The counts of the operator dashboard (/api/v1/saas/dashboard), as tiles.
  def overview
    metrics = ::Saas::DashboardMetrics.new.call
    orgs, users, mail = metrics.values_at(:organizations, :users, :mail)
    render json: { tiles: [
      { label: "Organizations", value: orgs[:total], resource: "organizations" },
      { label: "Suspended organizations", value: orgs[:suspended], resource: "organizations", view: SUSPENDED },
      { label: "New organizations, last 7 days", value: orgs[:new_7d] },
      { label: "Organizations on a paid plan", value: metrics[:plans][:paid] },
      { label: "Users", value: users[:total], resource: "users" },
      { label: "New users, last 7 days", value: users[:new_7d] },
      { label: "Domains", value: orgs[:domains_total], resource: "domains" },
      { label: "Mail received, last 7 days", value: mail[:inbound_7d] },
      { label: "Mail sent, last 7 days", value: mail[:outbound_7d] },
      { label: "Disk used", value: metrics[:disk][:bytes_stored], unit: "bytes" },
      { label: "Waiting for an invite", value: WaitlistSignup.pending.count,
        resource: "waitlist", view: WaitlistSignup::STATUS_PENDING }
    ] }
  end

  def index
    res = find_resource("list")
    unknown = request.query_parameters.keys - LIST_PARAMS
    bad_request!("A list takes: #{LIST_PARAMS.join(', ')}") if unknown.any?
    scope = rows(res)

    if (view = query_param("view"))
      found = res[:views].find { |v| v[:name] == view } or bad_request!("Unknown view")
      scope = found[:scope].call(scope)
    end
    if (q = query_param("q"))
      bad_request!("This list has no search") unless res[:search]
      scope = res[:search_scope].call(scope, "%#{ActiveRecord::Base.sanitize_sql_like(q)}%")
    end
    scope = filtered(res, scope)

    limit = query_param("limit") || "50"
    bad_request!("limit is a number from 1 to 200") unless limit.match?(/\A\d{1,4}\z/) && limit.to_i.positive?
    limit = [ limit.to_i, 200 ].min
    offset = cursor_offset(query_param("after"))

    page = sorted(res, scope).offset(offset).limit(limit + 1)
    page = page.preload(res[:preload]) if res[:preload]
    rows = page.to_a
    counts = counts_for(res, rows.first(limit).map(&:id))
    # A list item carries every field but the long ones.
    fields = res[:fields].reject { |field| %w[text json].include?(field[:type]) }

    render json: {
      items: rows.first(limit).map { |record| item(res, record, counts, fields) },
      # ponytail: the cursor is an offset. Fine for an operator paging a few
      # thousand rows; move to a keyset on (sort column, id) if deep pages get slow.
      next: rows.size > limit ? Base64.urlsafe_encode64((offset + limit).to_s, padding: false) : nil,
      # ponytail: an exact count per request. Drop `total` (it is optional) if
      # one of these tables grows past what COUNT(*) answers quickly.
      total: scope.count
    }
  end

  def show
    res = find_resource("show")
    render json: item(res, find_record(res))
  end

  # Only an organization takes an update. Each field is the write of its own
  # /api/v1/saas endpoint, with that endpoint's audit action.
  def update
    res = find_resource("update")
    record = find_record(res)
    values = coerce(res[:fields].select { |f| f[:update] }, body_object("values"), complete: false)

    ActiveRecord::Base.transaction do
      if values.key?("name")
        record.update!(name: values["name"])
        audit!(SaasAuditLog::ACTION_ORG_UPDATE, target: record, metadata: { fields: %w[name] })
      end
      if values.key?("mailbox_limit")
        record.update!(mailbox_limit: values["mailbox_limit"])
        audit!(SaasAuditLog::ACTION_ORG_MAILBOX_LIMIT, target: record,
               metadata: { mailbox_limit: values["mailbox_limit"] })
      end
      if values.key?("disk_quota_gb")
        record.update!(disk_quota_override_gb: values["disk_quota_gb"])
        audit!(SaasAuditLog::ACTION_ORG_DISK_QUOTA, target: record, metadata: { quota_gb: values["disk_quota_gb"] })
      end
    end

    render json: { item: item(res, record) }
  end

  def run_action
    res = find_resource
    record = find_record(res)
    action = res[:actions].find { |a| a[:name] == request.path_parameters[:action_name] } or
      refuse!(404, "not_found", "Not found")
    unless action[:available].nil? || action[:available].call(record)
      refuse!(409, "conflict", "#{action[:label]} is not available for this #{res[:singular].downcase}")
    end
    input = coerce(action[:input] || [], body_object("input"), complete: true)

    reveal = nil
    gone = false
    message =
      case action[:name]
      when "suspend"
        record.suspend!(input["reason"])
        audit!(SaasAuditLog::ACTION_ORG_SUSPEND, target: record, metadata: { reason: input["reason"] })
        "#{record.name} is suspended"
      when "unsuspend"
        record.unsuspend!
        audit!(SaasAuditLog::ACTION_ORG_UNSUSPEND, target: record)
        "#{record.name} is active again"
      when "set_plan"
        plan = input["plan"] && (Plan.find_by(key: input["plan"]) or refuse!(422, "invalid", INVALID, "plan" => "is not a plan"))
        record.update!(plan: plan)
        audit!(SaasAuditLog::ACTION_ORG_PLAN, target: record, metadata: { plan: plan&.name })
        plan ? "Plan set to #{plan.name}" : "The plan follows the subscription again"
      when "wipe"
        # The audit row keeps who it was: the organization is gone after this.
        snapshot = { key: record.key, domain: record.default_domain&.name, name: record.name }
        record.destroy!
        audit!(SaasAuditLog::ACTION_ORG_WIPE, metadata: snapshot)
        gone = true
        "#{snapshot[:name]} was deleted with all of its data"
      when "reset_password"
        # ponytail: mailed only, as /api/v1/saas does. Returning the link as a
        # `reveal` would let every Owner and Admin of the Pushleft organization
        # sign in as any user. PasswordResetService would have to return its URL.
        PasswordResetService.call(record) or refuse!(409, "conflict", "This user has no email address")
        audit!(SaasAuditLog::ACTION_USER_RESET_PASSWORD, target: record)
        "A reset link was mailed to #{record.billing_email}"
      when "disable"
        Membership.transaction do
          Membership.where(user: record).update_all(status: Membership::STATUS_DISABLED, updated_at: Time.current)
          ::Disk::KeyGrant.freeze_holders!(Membership.where(user: record).select(:id))
        end
        SessionRevoker.revoke_user!(record)
        audit!(SaasAuditLog::ACTION_USER_DISABLE, target: record)
        "#{NAME.call(record)} is disabled and signed out"
      when "enable"
        Membership.where(user: record, status: Membership::STATUS_DISABLED)
                  .update_all(status: Membership::STATUS_ACTIVE, updated_at: Time.current)
        audit!(SaasAuditLog::ACTION_USER_ENABLE, target: record)
        "#{NAME.call(record)} is enabled"
      when "offboard"
        offboard(record, Organization.where(id: Membership.where(user: record).select(:organization_id)).to_a, input)
        audit!(SaasAuditLog::ACTION_USER_OFFBOARD, target: record)
        "#{NAME.call(record)} was removed from every organization"
      when "remove"
        user, organization = record.user, record.organization
        offboard(user, [ organization ], input)
        audit!(SaasAuditLog::ACTION_ORG_MEMBER_REMOVE, target: organization, metadata: { user: user.key })
        gone = true
        "#{NAME.call(user)} was removed from #{organization.name}"
      when "invite"
        record.generate_invite_token!(invited_by: @claims["sub"])
        WaitlistMailerService.send_invite(record)
        audit!(SaasAuditLog::ACTION_WAITLIST_INVITE, target: record, metadata: { email: record.email })
        reveal = { label: "Invitation link", value: WaitlistMailerService.invite_url(record.invite_token) }
        "An invitation was mailed to #{record.email}"
      end

    render json: { item: (item(res, record.reload) unless gone), message: message, reveal: reveal }.compact
  end

  def not_found
    refuse!(404, "not_found", "Not found")
  end

  private

  # ── The signed request ───────────────────────────────────────────────────────

  def authenticate
    jwks, audience = ENV["PUSHLEFT_ADMIN_JWKS"], ENV["PUSHLEFT_ADMIN_AUDIENCE"]
    return head(:not_found) if jwks.blank? || audience.blank?

    @claims = verified_claims(jwks, audience)
    render_error(401, "unauthorized", "A valid Pushleft admin token is required") unless @claims
  end

  # The claims of the bearer token, or nil unless all of these hold:
  #   1. the header alg is ES256 (never none, never a symmetric algorithm);
  #   2. the signature verifies with the key that kid names in the key set;
  #   3. iss is Pushleft and aud is this environment's audience;
  #   4. exp is not past and iat is not ahead, with at most 30 seconds of clock
  #      difference;
  #   5. method and path are this request's, compared with the raw target;
  #   6. body is the SHA-256 of the bytes received.
  # Anything unexpected in here (a malformed key set included) refuses.
  #
  # ponytail: no jti replay memory. A token already works for one method, path
  # and body for 60 seconds. Refusing a second use needs a cache that every web
  # process shares; Rails.cache on the shared store would do.
  def verified_claims(jwks, audience)
    token = request.authorization.to_s[/\ABearer ([\w.-]+)\z/, 1] or return nil
    keys = JSON.parse(jwks).fetch("keys").select { |key| key["kty"] == "EC" && key["crv"] == "P-256" }
    claims, = JWT.decode(token, nil, true,
                         algorithms: [ "ES256" ], jwks: { "keys" => keys },
                         iss: ISSUER, verify_iss: true, aud: audience, verify_aud: true, leeway: 30,
                         required_claims: %w[iss aud sub iat exp method path body])

    # The library checks iat without the leeway, so it is checked here.
    claims if claims["iss"] == ISSUER && claims["aud"] == audience &&
              claims["sub"].is_a?(String) && claims["sub"].present? &&
              claims["iat"].is_a?(Numeric) && claims["iat"] <= Time.now.to_i + 30 &&
              claims["method"] == request.request_method &&
              claims["path"] == request_target &&
              claims["body"] == Digest::SHA256.hexdigest(request.raw_post.to_s)
  rescue StandardError => e
    Rails.logger.warn("[PushleftAdmin] token refused: #{e.class}")
    nil
  end

  # The request target as the client sent it. Rails' own fullpath is rebuilt
  # from the parsed path and is only the fallback for servers without REQUEST_URI.
  def request_target
    request.get_header("REQUEST_URI").presence || request.original_fullpath
  end

  # The operator is a person in Pushleft, not an AdminCredential: their email
  # and the request id go into the row's metadata.
  def audit!(action, target: nil, metadata: {})
    SaasAuditLog.record!(admin: nil, action: action, target: target, ip: request.remote_ip,
                         metadata: metadata.merge(operator: @claims["sub"], request_id: @claims["jti"]))
  end

  # ── Lookups ──────────────────────────────────────────────────────────────────

  def find_resource(operation = nil)
    res = RESOURCES.find { |r| r[:name] == request.path_parameters[:resource] }
    refuse!(404, "not_found", "Not found") unless res && (operation.nil? || res[:can].include?(operation))
    res
  end

  def rows(res)
    res[:scope] ? res[:scope].call : res[:model].all
  end

  def find_record(res)
    id = request.path_parameters[:id]
    refuse!(404, "not_found", "Not found") unless key?(res[:model], id)
    rows(res).find_by!(key: id)
  end

  # A public id of that model: its prefix and a nanoid.
  def key?(model, value)
    value.is_a?(String) && value.match?(/\A#{model.key_prefix}_[A-Za-z0-9_-]{1,40}\z/)
  end

  def model_of(field)
    RESOURCES.find { |r| r[:name] == field[:resource] }[:model]
  end

  def counts_for(res, ids)
    res[:fields].select { |f| f[:count] }.to_h { |f| [ f[:name], f[:count].call(ids) ] }
  end

  def item(res, record, counts = counts_for(res, [ record.id ]), fields = res[:fields])
    {
      id: record.key,
      values: fields.to_h do |field|
        value = if field[:count] then counts[field[:name]].fetch(record.id, 0)
        elsif field[:read] then field[:read].call(record)
        else record.public_send(field[:column] || field[:name])
        end
        [ field[:name], value.respond_to?(:iso8601) ? value.utc.iso8601 : value ]
      end,
      actions: res[:actions].select { |a| a[:available].nil? || a[:available].call(record) }.map { |a| a[:name] }
    }
  end

  # ── Lists ────────────────────────────────────────────────────────────────────

  def query_param(name)
    value = request.query_parameters[name]
    bad_request!("#{name} takes one value") unless value.nil? || (value.is_a?(String) && !value.include?("\0"))
    value.presence
  end

  # filter[field]=a,b matches any of the values; filter[field][gte] and [lte]
  # bound dates and numbers. Field names and columns come from RESOURCES and
  # values are cast by field type, so nothing from the query string reaches SQL
  # as text.
  def filtered(res, scope)
    filters = request.query_parameters["filter"]
    return scope if filters.nil?
    bad_request!("Filters are given as filter[field]=value") unless filters.is_a?(Hash)

    filters.each do |name, raw|
      field = res[:fields].find { |f| f[:name] == name && f[:filter] }
      unless field
        allowed = res[:fields].select { |f| f[:filter] }.map { |f| f[:name] }.join(", ")
        bad_request!("This list filters on: #{allowed}")
      end
      column = field[:column] || field[:name]

      if raw.is_a?(Hash)
        unless %w[datetime integer].include?(field[:type]) && (raw.keys - %w[gte lte]).empty?
          bad_request!("#{field[:name]}: only dates and numbers take gte and lte")
        end
        scope = scope.where(column => cast(field, raw["gte"])..) if raw.key?("gte")
        scope = scope.where(column => ..cast(field, raw["lte"])) if raw.key?("lte")
      else
        values = raw.is_a?(String) ? raw.split(",").map { |value| cast(field, value) } : []
        bad_request!("#{field[:name]}: give one or more values, separated by commas") if values.empty?
        scope = if field[:where] then field[:where].call(scope, values)
        elsif field[:type] == "ref" then scope.where(column => model_of(field).where(key: values).select(:id))
        else scope.where(column => values)
        end
      end
    end
    scope
  end

  # A filter value from the query string, as the type of its field.
  def cast(field, raw)
    value =
      if !raw.is_a?(String) || raw.include?("\0") then nil
      else
        case field[:type]
        when "enum"     then raw if field[:options].any? { |option| option[:value] == raw }
        when "ref"      then raw if key?(model_of(field), raw)
        when "integer"  then raw.to_i if raw.match?(/\A-?\d{1,18}\z/)
        when "datetime" then parse_time(raw)
        end
      end
    bad_request!("#{field[:name]}: not a valid #{field[:type]} value") if value.nil?
    value
  end

  def sorted(res, scope)
    sort = query_param("sort") || res[:default_sort]
    field = res[:fields].find { |f| f[:name] == sort.delete_prefix("-") && f[:sort] }
    unless field
      allowed = res[:fields].select { |f| f[:sort] }.map { |f| f[:name] }.join(", ")
      bad_request!("This list sorts on: #{allowed}")
    end

    table = res[:model].arel_table
    column = table[field[:column] || field[:name]]
    if sort.start_with?("-")
      scope.order(column.desc.nulls_last, table[:id].desc)
    else
      scope.order(column.asc, table[:id].asc)
    end
  end

  def cursor_offset(cursor)
    return 0 unless cursor
    offset = Base64.urlsafe_decode64(cursor)
    raise ArgumentError unless offset.match?(/\A\d{1,9}\z/)
    offset.to_i
  rescue ArgumentError
    bad_request!("after is not a cursor from this list")
  end

  # ── Writes ───────────────────────────────────────────────────────────────────

  # The object under `key` in the JSON body, which holds nothing else. Parsed
  # here from the bytes that the token's body hash covers, not from Rails' params.
  def body_object(key)
    raw = request.raw_post
    body = raw.blank? ? {} : JSON.parse(raw)
    object = body.is_a?(Hash) && (body.keys - [ key ]).empty? ? body.fetch(key, {}) : nil
    bad_request!(%(The body is a JSON object with "#{key}" only)) unless object.is_a?(Hash)
    object
  rescue JSON::ParserError
    bad_request!("The body is not valid JSON")
  end

  # Checks written values (an update, an action's input) against their field
  # definitions and returns them typed. Refuses with one message per field, a
  # field that is not declared included. `complete` also demands every required
  # field, as an action does.
  def coerce(fields, given, complete:)
    errors = (given.keys - fields.map { |f| f[:name] }).to_h { |name| [ name, "cannot be set here" ] }
    values = {}

    fields.each do |field|
      name = field[:name]
      unless given.key?(name)
        errors[name] = "is required" if complete && field[:required]
        next
      end

      value = given[name]
      value = value.strip if value.is_a?(String)
      if value.nil? || value == ""
        field[:required] ? errors[name] = "is required" : values[name] = nil
      elsif (problem = problem_with(field, value))
        errors[name] = problem
      else
        values[name] = value
      end
    end

    refuse!(422, "invalid", INVALID, errors) if errors.any?
    values
  end

  def problem_with(field, value)
    case field[:type]
    when "integer"
      if !value.is_a?(Integer) then "must be a whole number"
      elsif value < field[:min] || value > field[:max] then "must be from #{field[:min]} to #{field[:max]}"
      end
    when "enum"
      "is not one of the options" unless field[:options].any? { |option| option[:value] == value }
    when "ref"
      "does not exist" unless key?(model_of(field), value)
    else
      if !value.is_a?(String) || value.include?("\0") then "must be text"
      elsif field[:max_length] && value.length > field[:max_length] then "is too long (at most #{field[:max_length]} characters)"
      end
    end
  end

  # RFC 3339 only, within the years a timestamp column holds.
  def parse_time(value)
    time = Time.iso8601(value)
    time if time.year.between?(1970, 9999)
  rescue ArgumentError
    nil
  end

  # Takes `user` out of `organizations` as /api/v1/saas does: the mail and the
  # old address go the way the operator chose, then every session is revoked.
  def offboard(user, organizations, input)
    reroute = input["alias_handling"] == MailboxAlias::MODE_REROUTE
    if reroute != input["reroute_target"].present?
      refuse!(422, "invalid", INVALID,
              "reroute_target" => reroute ? "is required" : "only with Deliver to a colleague")
    end

    UserOffboarder.new(user: user, organizations: organizations, acting_user: nil,
                       data_handling: input["data_handling"], alias_handling: input["alias_handling"],
                       reroute_target_key: input["reroute_target"]).call
    SessionRevoker.revoke_user!(user)
  rescue UserOffboarder::InvalidRerouteTarget
    refuse!(422, "invalid", INVALID, "reroute_target" => "must be an active member of the same organization")
  end

  # ── Errors ───────────────────────────────────────────────────────────────────

  def refuse!(status, code, message, fields = nil)
    raise Refusal.new(status, code, message, fields)
  end

  def bad_request!(message)
    refuse!(400, "bad_request", message)
  end

  def render_error(status, code, message, fields = nil)
    render json: { error: { code: code, message: message, fields: fields }.compact }, status: status
  end
end
