class MembershipSerializer < ::ApplicationSerializer
  attributes :role, :status, :created_at

  # Domain access. all_domains = true means the member sees the whole org pool
  # (always true for owners/admins); otherwise `domains` lists the specific
  # domains whose pool slice they may see.
  attribute :all_domains do |m|
    m.all_domains_access?
  end

  attribute :domains do |m|
    ids = params[:domain_ids]
    m.all_domains_access? ? [] : m.domains.select { |d| ids.nil? || ids.include?(d.id) }.map { |d| { id: d.key, name: d.name } }
  end

  # Scoped-member refinement: granted domains minus teammates' personal
  # mailboxes (enforced in Conversation.visible_to). No effect for
  # admins/all-domains members.

  # Extra From addresses an admin granted (info@, sales@ — console member page).
  attribute :send_as_addresses do |m|
    MembershipSerializer.on_domains(m.send_as_addresses, params[:domain_ids], m.organization)
  end

  # Every address this member has across the org's domains (one per mailbox).
  attribute :email_addresses do |m|
    MembershipSerializer.on_domains(m.email_addresses, params[:domain_ids], m.organization)
  end

  # Per-domain mailboxes (id + address) for management UIs. Enumerates the loaded
  # association directly so a `includes(mailboxes: :domain)` upstream isn't undone
  # by a fresh `.includes` query here.
  attribute :mailboxes do |m|
    ids = params[:domain_ids]
    m.mailboxes.select { |mb| ids.nil? || ids.include?(mb.domain_id) }
      .map { |mb| { id: mb.key, local_part: mb.local_part, email_address: mb.email_address, domain: mb.domain.name } }
  end

  # With params[:domain_ids] (a domain-scoped viewer), only addresses on those domains.
  def self.on_domains(addresses, domain_ids, org)
    return addresses if domain_ids.nil?

    hosts = org.domains.select { |d| domain_ids.include?(d.id) }.map { |d| d.name.downcase }
    addresses.select { |a| hosts.include?(a.split("@", 2).last.to_s.downcase) }
  end

  one :user, serializer: UserSerializer
end
