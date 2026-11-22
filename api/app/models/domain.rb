# A domain owned by an organization. First-class (an org owns many, all equal);
# carries the DNS-verification lifecycle that used to live on Organization. There
# is no primary/secondary distinction — every domain pools mail identically. When
# the org needs a single canonical domain (branding, default from-address), it
# derives one via Organization#default_domain (the oldest).
class Domain < ApplicationRecord
  key_prefix "dom"

  STATUSES = %w[pending_dns verified receiving_mail error].freeze
  STATUS_PENDING_DNS = "pending_dns".freeze
  STATUS_VERIFIED = "verified".freeze
  STATUS_RECEIVING_MAIL = "receiving_mail".freeze
  STATUS_ERROR = "error".freeze
  # Statuses at which the MX receiver accepts mail for the domain.
  ACCEPTING_STATUSES = [STATUS_VERIFIED, STATUS_RECEIVING_MAIL].freeze

  belongs_to :organization
  has_one :mta_sts_policy, dependent: :destroy
  has_one :tls_rpt_config, dependent: :destroy
  has_many :mailboxes, dependent: :destroy
  has_many :mailbox_aliases, dependent: :nullify
  has_many :domain_keys, dependent: :destroy
  # Threads attributed to this domain (org-wide pool, one domain each). Nullify on
  # domain removal so history survives as unattributed rather than being deleted.
  # Shared addresses (info@, support@): each one is a folder for the people
  # who can read it (AddressFolders). [{ "local_part", "display_name" }]
  validate :shared_addresses_shape
  has_many :conversations, dependent: :nullify
  # Per-member access grants to this domain's pool slice.
  has_many :membership_domains, dependent: :destroy
  has_many :members, through: :membership_domains, source: :membership
  # Disk shares of this team. Removing the domain must not open them to the whole
  # org: they become members-only first (Disk::Share.release_domain!).
  has_many :disk_shares, class_name: "Disk::Share", dependent: nil
  before_destroy { Disk::Share.release_domain!(self) }

  validates :name, presence: true, uniqueness: { case_sensitive: false }
  validates :status, inclusion: { in: STATUSES }
  validate :e2ee_requires_entitlement

  before_validation { self.name = name.downcase.strip if name.present? }

  # Nudge live web/desktop clients to re-pull /account so a domain added, removed,
  # or status-changed out-of-band (console, admin CLI, another session) appears
  # without a webview reload. Reuses the org channel that already carries new-mail
  # signals (see OrganizationChannel / orgLiveMail.js). Status and icon are the
  # mutable fields the client renders, so update only fires when one changes.
  after_commit :broadcast_domain_changed, on: %i[create destroy]
  after_commit :broadcast_domain_changed, on: :update, if: -> { previous_changes.key?("status") || previous_changes.key?("icon_url") }

  # Billing lock: a domain beyond the org's (downgraded) plan limit is locked and
  # stops receiving mail until the org upgrades again.
  def locked?
    locked_at.present?
  end

  def accepting_mail?
    !locked? && ACCEPTING_STATUSES.include?(status)
  end

  # Host the open-tracking pixel is served from for this domain: the verified
  # custom host (track.tuli.com) or the inbox2 default. Custom host only once its
  # CNAME/cert are verified — otherwise the pixel would 5xx and undercount.
  def tracking_host
    if tracking_domain.present? && tracking_domain_verified_at.present?
      tracking_domain
    else
      Tracking::DEFAULT_HOST
    end
  end

  # Persist the latest per-record DNS check (moved from Organization). MX drives
  # status — verified vs back to pending — except for a domain already receiving
  # mail, whose status only the inbound pipeline manages.
  def record_dns_check!(result)
    attrs = { dns_checks: result[:checks], dns_checked_at: Time.current }
    unless status == STATUS_RECEIVING_MAIL
      attrs[:status] = result[:mx_ok] ? STATUS_VERIFIED : STATUS_PENDING_DNS
    end
    update!(attrs)
  end

  # URL workspace slug — the domain occupies the path's first segment
  # (/:slug/mail/inbox) in the web client. Derived the same way as the org slug
  # (`name.parameterize`); domains are globally unique so the slug is too. The
  # primary domain's slug therefore equals its org's slug.
  def slug
    name.parameterize
  end

  # The domain's current (non-retired, highest-version) sealing key — what the MX
  # seals inbound DEKs to. Nil until Phase-B key provisioning has minted v1.
  def current_e2ee_key
    domain_keys.active.order(version: :desc).first
  end


  # Whether a local part (tag dropped) is on this domain's shared list.
  def shared_local?(local)
    base = Mailbox.base_local_part(local.to_s.downcase)
    Array(shared_addresses).any? { |a| a["local_part"] == base }
  end
  private

  def broadcast_domain_changed
    ActionCable.server.broadcast("organization_#{organization.key}", { type: "domain_changed" })
  rescue => e
    Rails.logger.warn("[Domain] domain_changed broadcast error: #{e.message}")
  end

  # Paywall + provisioning guard (docs/E2EE.md Phase A/B): flipping the switch on
  # requires the plan entitlement AND a minted sealing key — no half-enable (an
  # enabled-but-keyless domain would silently fall back to plaintext). Only
  # checked when the flag is being turned on, so a later plan downgrade never
  # breaks unrelated saves.
  def e2ee_requires_entitlement
    return unless e2ee_enabled && e2ee_enabled_changed?

    unless organization&.e2ee_entitled?
      errors.add(:e2ee_enabled, "requires a plan that includes E2EE message sealing")
    end
    errors.add(:e2ee_enabled, "requires a provisioned domain key") if current_e2ee_key.nil?
  end

  def shared_addresses_shape
    list = Array(shared_addresses)
    locals = list.map { |a| a.is_a?(Hash) ? a["local_part"].to_s : "" }
    bad = locals.reject { |l| l.match?(Membership::LOCAL_PART_FORMAT) }
    errors.add(:shared_addresses, "must be plain address names (#{bad.join(', ')})") if bad.any?
    errors.add(:shared_addresses, "has a name twice") if locals.uniq.size != locals.size
    reserved = locals & AddressFolders::RESERVED
    errors.add(:shared_addresses, "can't use a folder name (#{reserved.join(', ')})") if reserved.any?
    # A member's mailbox or username is their own address (personal_membership_id_for).
    taken = locals & mailboxes.pluck(:local_part)
    errors.add(:shared_addresses, "can't include a member's own mailbox (#{taken.join(', ')})") if taken.any?
    retired = locals & mailbox_aliases.pluck(:local_part)
    errors.add(:shared_addresses, "can't include a retired mailbox (#{retired.join(', ')})") if retired.any?
  end
end
