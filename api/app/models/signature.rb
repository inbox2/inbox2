# A mail signature (spec 8.1.7). Three kinds, by who owns it:
#   - personal: membership set. With from_address it is for that one address;
#     without, and is_default, it is the person's default.
#   - domain:   membership nil, domain set. An admin's signature for every
#     address on the domain (lalaaji.com: info@, wesley@, each person's own).
#   - org-wide: membership and domain nil. The fallback for the whole org.
# The body is HTML. Images are inline data: URIs, which OutboundMailPublisher
# turns into cid: parts of a multipart/related message.
class Signature < ApplicationRecord
  key_prefix "sig"

  MAX_BODY_BYTES = 600.kilobytes
  # {{name}} and {{email}} in a body: the sender's name and the From address,
  # so one domain signature works for everyone who sends from the domain.
  VARIABLES = %w[name email].freeze

  TAGS = %w[a b strong i em u s br p div span img table tbody thead tr td th hr ul ol li h1 h2 h3 h4 small font blockquote].freeze
  ATTRIBUTES = %w[href src alt title width height style align valign colspan rowspan border cellpadding cellspacing color face size target].freeze

  belongs_to :organization
  belongs_to :membership, optional: true
  belongs_to :domain, optional: true

  validates :name, presence: true
  validate :body_size
  validate :domain_in_org

  before_validation :sanitize_body
  after_save :clear_other_defaults, if: -> { is_default && saved_change_to_is_default? && personal? }

  scope :org_wide, -> { where(membership_id: nil) }
  scope :personal_for, ->(membership) { where(membership: membership) }

  def personal? = membership_id.present?

  # What `membership` sees: their own, the signatures of the domains they work
  # on, and the org-wide one only when they reach the org beyond one mailbox.
  # (A mailbox-only member on lalaaji.com never sees husttle.com's signature.)
  def self.visible_to(membership)
    sigs = membership.organization.signatures
    shared = sigs.org_wide.where(domain_id: membership.home_domain_ids)
    shared = shared.or(sigs.org_wide.where(domain_id: nil)) if membership.org_wide_access?
    shared.or(sigs.personal_for(membership))
  end

  # The signature that goes under mail `membership` sends from `address`, or
  # nil. Their own signature for the address wins, then the domain's, then
  # their default, then the org's. Among several for one target, the newest edit.
  def self.for_address(membership, address, signatures = nil)
    addr = address.to_s.downcase
    host = addr.split("@", 2)[1]
    sigs = signatures || visible_to(membership).includes(:domain).to_a
    # Two for the same target: the one edited last wins.
    mine, team = sigs.sort_by { -_1.updated_at.to_f }.partition(&:personal?)
    mine.find { |s| s.from_address.to_s.downcase == addr } ||
      team.find { |s| s.domain && s.domain.name.downcase == host } ||
      mine.find { |s| s.from_address.blank? && s.is_default } ||
      team.find { |s| s.domain_id.nil? }
  end

  # The body with the variables filled in for this sender and address.
  def render_for(membership, address)
    name = membership.user.display_name.presence || membership.user.username
    values = { "name" => name, "email" => address.to_s.downcase }
    body_html.to_s.gsub(/\{\{\s*(#{VARIABLES.join('|')})\s*\}\}/) { ERB::Util.html_escape(values[Regexp.last_match(1)]) }
  end

  # Plain text for body_plain, after the "-- " line mail clients expect.
  def self.plain_text(html)
    marked = html.to_s.gsub(%r{<br\s*/?>}i, "\n").gsub(%r{</(p|div|tr|li|h\d)>}i, "\\0\n")
    text = Nokogiri::HTML5.fragment(marked).text.gsub(/[ \t]+\n/, "\n").gsub(/\n{3,}/, "\n\n").strip
    text.empty? ? "" : "-- \n#{text}"
  end

  private

  # Org-wide and domain signatures show inside every member's composer, so the
  # body is reduced to formatting tags. data: image URIs survive (Loofah keeps
  # data: for image types only).
  def sanitize_body
    return if body_html.nil?

    self.body_html = Rails::HTML5::SafeListSanitizer.new.sanitize(body_html, tags: TAGS, attributes: ATTRIBUTES)
  end

  # One default per person.
  def clear_other_defaults
    Signature.where(membership_id: membership_id).where.not(id: id).update_all(is_default: false)
  end

  def body_size
    errors.add(:body_html, "is too large (images make it over #{MAX_BODY_BYTES / 1.kilobyte} KB)") if body_html.to_s.bytesize > MAX_BODY_BYTES
  end

  def domain_in_org
    errors.add(:domain, "is not in this organization") if domain && domain.organization_id != organization_id
  end
end
