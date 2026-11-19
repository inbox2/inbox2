# An action label Jev can put on a thread (docs/Triage.md "Built-in labels").
# Every org starts with the thirteen built-ins; their slug is wire-stable (stored
# on conversations.triage_label, rendered by every client) so it can't change,
# and they can't be deleted. Orgs add their own custom labels next to them.
class TriageLabel < ApplicationRecord
  key_prefix "tlb"

  NEEDS_ANSWER = "needs_answer".freeze
  NEEDS_ANSWER_OTHER = "needs_answer_other".freeze
  WAITING_REPLY = "waiting_reply".freeze
  NEEDS_APPROVAL = "needs_approval".freeze
  SCHEDULING = "scheduling".freeze
  ACTION_REQUIRED = "action_required".freeze
  # The fallback: never disableable, and where an unknown answer lands.
  FYI = "fyi".freeze
  RESOLVED = "resolved".freeze
  # Added 2026-10-20 (docs/plans/lore.md §1): appended, so existing orgs get
  # them after their own labels (ensure_defaults).
  PAYMENT_DUE = "payment_due".freeze
  TO_REVIEW = "to_review".freeze
  READ_LATER = "read_later".freeze
  RECEIPT = "receipt".freeze
  NOTIFICATION = "notification".freeze
  # Labels that are not a Lore to-do: done, or a "Handled for you" bucket
  # (web lib/lore.js). Every other label, custom ones included, is an open item.
  NOT_LORE_TODO = [RESOLVED, FYI, RECEIPT, NOTIFICATION].freeze
  # Lore's personal buckets: on a shared MX domain a tick hides these for the
  # ticking member only (LoreMemberDone); every other label archives for the team.
  # Mirrored by each client's Lore rules (web lib/lore.js PERSONAL_LABELS).
  PERSONAL = [READ_LATER, FYI, RECEIPT, NOTIFICATION].freeze

  # Must equal fixtures/parity/fixtures.json → jev_triage.builtin_labels (the
  # parity spec asserts it). Order = default position.
  BUILTIN = [
    { slug: NEEDS_ANSWER, name: "Needs answer",
      description: "A real person directly asked the owner a question or made a request and is waiting for the owner's personal reply",
      not_for: "Bulk, marketing, newsletter or automated mail; questions aimed at someone else" },
    { slug: NEEDS_ANSWER_OTHER, name: "Reply from someone else",
      description: "A reply is expected, but from someone other than the owner, for example the owner is only copied or the question is aimed at a colleague",
      not_for: "" },
    { slug: WAITING_REPLY, name: "Waiting for reply",
      description: "The owner sent the last message and is waiting for the other side to respond",
      not_for: "A closing thanks that ends the conversation" },
    { slug: NEEDS_APPROVAL, name: "Needs approval",
      description: "The owner is asked to approve or authorize someone else's request or work: a pull request, a purchase, time off, an expense, or a document prepared for their sign-off",
      not_for: "Bills, invoices or payments the owner has to pay" },
    { slug: SCHEDULING, name: "Scheduling",
      description: "Arranging or changing a meeting or a time, or a reminder or confirmation of an already-booked appointment with a concrete date and time, automated booking mail included",
      not_for: "Order, shipping or delivery updates" },
    { slug: ACTION_REQUIRED, name: "Action required",
      description: "The owner must personally complete a concrete task with a consequence: sign a contract, cancel a subscription, verify an account, upload a requested file or fill in a requested form",
      not_for: "Marketing calls to action such as get started, learn more or upgrade; bills, invoices or statements to pay or look over" },
    { slug: FYI, name: "FYI",
      description: "Informational, nothing is needed from the owner: announcements, promotions, product and service updates, threads the owner is only copied on, and anything else that asks nothing",
      not_for: "Newsletters and articles worth reading, receipts and order updates, automated system notifications" },
    { slug: RESOLVED, name: "Resolved",
      description: "The matter is concluded and nothing is left to do, such as a closing thanks or a confirmation that it is done",
      not_for: "" },
    { slug: PAYMENT_DUE, name: "To pay",
      description: "The owner has to pay something: an invoice, bill, payment reminder, failed direct debit or renewal fee that is not already paid or collected automatically",
      not_for: "Receipts and invoices that say they are already paid or will be collected automatically" },
    { slug: TO_REVIEW, name: "To review",
      description: "Data or a document for the owner to look over, with nothing to answer or do: bank or card statements, reports, dashboards, analytics, shared spreadsheets",
      not_for: "Documents the owner must sign or approve" },
    { slug: READ_LATER, name: "Read later",
      description: "Something worth reading but not urgent: newsletters, articles, essays and product launch letters the owner subscribed to",
      not_for: "Promotions, sales and discount offers" },
    { slug: RECEIPT, name: "Receipt",
      description: "A record of something already done or paid: a receipt, an invoice marked paid or collected automatically, an order, shipping or delivery confirmation",
      not_for: "" },
    { slug: NOTIFICATION, name: "Notification",
      description: "An automated system message: sign-in codes and links, security alerts, password resets, build, deploy, crash and monitoring alerts, app store processing notices",
      not_for: "Messages written by a real person" }
  ].freeze
  BUILTIN_SLUGS = BUILTIN.map { |l| l[:slug] }.freeze
  # Built-in texts as they shipped before the 2026-10-20 rewording. A row still
  # carrying one (nobody edited it) gets the current text when the new built-ins
  # are seeded — otherwise the old fyi would still claim receipts and
  # notifications. Mirrors triage::LEGACY_TEXTS in the Rust core.
  LEGACY_TEXTS = [
    { slug: ACTION_REQUIRED,
      description: "The owner must personally complete a concrete task with a consequence: pay a bill, invoice or statement, renew or cancel a subscription, sign a contract, verify an account, upload a requested file",
      not_for: "Marketing calls to action such as get started, learn more or upgrade" },
    { slug: FYI,
      description: "Informational, nothing is needed from the owner: newsletters, marketing, announcements, receipts, shipping and payment confirmations, notifications and digests",
      not_for: "" },
    { slug: SCHEDULING,
      description: "Arranging or changing a meeting or a time, or a reminder or confirmation of an already-booked appointment with a concrete date and time, automated booking mail included",
      not_for: "" }
  ].freeze
  # A custom label can't shadow a built-in or the space question's escape hatch.
  RESERVED_SLUGS = (BUILTIN_SLUGS + [JevTriage::NO_MATCH]).freeze
  SLUG_FORMAT = /\A[a-z0-9_]{1,40}\z/

  # Provenance for a label set by a deterministic rule rather than Jev.
  SOURCE_RULE_SENT = "rule:sent".freeze
  # A sign-in code or magic link (OtpDetector) → NOTIFICATION, no Jev label call.
  SOURCE_RULE_OTP = "rule:otp".freeze
  # Provenance for a label a person picked (Triage › Label). Jev overwrites it on
  # the next inbound message or an explicit re-run (docs/Triage.md "Manual triage").
  SOURCE_MANUAL = "manual".freeze
  # Appended to triage_source when Lore auto mode filed the thread away
  # (docs/Triage.md "Auto mode"), e.g. `jev:jev-1.13.0+auto`.
  SOURCE_AUTO_SUFFIX = "+auto".freeze

  belongs_to :organization

  validates :name, presence: true
  validates :description, presence: true
  validates :slug, format: { with: SLUG_FORMAT, message: "must be 1-40 lowercase letters, digits or underscores" },
                   uniqueness: { scope: :organization_id }
  validate :custom_slug_not_reserved
  validate :builtin_slug_immutable
  validate :fyi_stays_enabled

  before_validation :derive_slug, on: :create
  before_destroy :keep_builtins

  scope :ordered, -> { order(:position, :id) }

  # Seed an org's built-ins, idempotently (mirrors Space.ensure_default_spaces).
  # A new org gets them at their BUILTIN index; an org that already has labels
  # gets any built-in added in a later release after its last label.
  # Returns the org's labels in position order.
  def self.ensure_defaults(organization)
    existing = organization.triage_labels.where(slug: BUILTIN_SLUGS).pluck(:slug)
    refresh_legacy_texts(organization) if existing.any? && existing.size < BUILTIN.size
    last = organization.triage_labels.maximum(:position)
    BUILTIN.each_with_index do |data, index|
      next if existing.include?(data[:slug])

      position = last ? (last += 1) : index
      organization.triage_labels.create!(data.merge(builtin: true, enabled: true, position: position))
    end
    organization.triage_labels.ordered.to_a
  end

  def self.refresh_legacy_texts(organization)
    LEGACY_TEXTS.each do |old|
      current = BUILTIN.find { |l| l[:slug] == old[:slug] }
      organization.triage_labels.where(builtin: true, **old)
                  .update_all(description: current[:description], not_for: current[:not_for], updated_at: Time.current)
    end
  end
  private_class_method :refresh_legacy_texts

  private

  def derive_slug
    self.slug = name.to_s.parameterize(separator: "_")[0, 40] if slug.blank?
  end

  def custom_slug_not_reserved
    errors.add(:slug, "is reserved") if !builtin && RESERVED_SLUGS.include?(slug)
  end

  def builtin_slug_immutable
    errors.add(:slug, "of a built-in label can't change") if builtin && persisted? && slug_changed?
  end

  def fyi_stays_enabled
    errors.add(:enabled, "can't be turned off for FYI (it is the fallback)") if slug == FYI && !enabled
  end

  # An org being destroyed takes its built-ins with it.
  def keep_builtins
    return if !builtin || destroyed_by_association

    errors.add(:base, "Built-in labels can't be deleted")
    throw :abort
  end
end
