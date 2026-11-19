# Resolves email addresses to the org's own people (docs/Calendar.md).
#
# `calendar_attendees` stores a bare string, so nothing could tell a colleague
# apart from an outside guest. Scheduling needs that distinction: a colleague
# has a calendar we can read for availability, a timezone to render their day
# in, and a name to label a row with. An outside guest has none of it.
#
# Resolution goes through Mailbox — the address unit under the multi-domain
# model — so it stays scoped to this organization's domains (E3).
class OrgDirectory
  Person = Struct.new(:email, :name, :timezone, :membership, :user, :internal, keyword_init: true) do
    def internal? = internal
  end

  # Falls back to the org's own timezone-less default rather than the server's,
  # so an unconfigured colleague still renders somewhere sensible.
  DEFAULT_TIMEZONE = "UTC".freeze

  # With a domain-scoped membership, only the people on that member's own
  # domains are the org's people; the rest resolve as outside guests (E3).
  def initialize(organization, membership: nil)
    @organization = organization
    @membership = membership
  end

  # => { "lowercased@address" => Person }
  def resolve(emails)
    wanted = Array(emails).filter_map { |e| e.to_s.downcase.presence }.uniq
    return {} if wanted.empty?

    found = internal_people(wanted)
    wanted.index_with do |email|
      found[email] || Person.new(email: email, name: nil, timezone: nil, membership: nil, internal: false)
    end
  end

  # Every address in the org, for the "invite a colleague" picker.
  def people
    mailbox_scope.map { |mbx| person_for(mbx) }.sort_by { |p| p.name.to_s.downcase }
  end

  private

  def internal_people(wanted)
    mailbox_scope
      .select { |mbx| wanted.include?(mbx.email_address.downcase) }
      .index_by { |mbx| mbx.email_address.downcase }
      .transform_values { |mbx| person_for(mbx) }
  end

  def mailbox_scope
    @mailbox_scope ||= begin
      scope = Mailbox.joins(:domain).where(domains: { organization_id: @organization.id })
      scope = scope.where(domain_id: @membership.home_domain_ids) if @membership && !@membership.all_domains_access?
      scope.includes(:domain, membership: :user).to_a
    end
  end

  def person_for(mailbox)
    user = mailbox.membership&.user
    Person.new(
      email: mailbox.email_address.downcase,
      name: user&.display_name.presence || user&.username,
      timezone: user&.default_timezone.presence || DEFAULT_TIMEZONE,
      membership: mailbox.membership,
      user: user,
      internal: true
    )
  end
end
