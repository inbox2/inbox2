# A send-only domain: an org sends from it through the ESP API, but its mail is
# not hosted here (no MX, no mailboxes, no inbox). Verified by the DKIM CNAME
# alone: the signature is what aligns the mail with the From domain.
class Esp::Domain < ApplicationRecord
  key_prefix "edom"

  STATUS_PENDING_DNS = "pending_dns".freeze
  STATUS_VERIFIED = "verified".freeze
  STATUSES = [STATUS_PENDING_DNS, STATUS_VERIFIED].freeze

  belongs_to :organization

  before_validation { self.name = name.to_s.downcase.strip }
  validates :name, presence: true, uniqueness: { case_sensitive: false },
    format: { with: /\A[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+\z/, message: "is not a domain name" }
  validates :status, inclusion: { in: STATUSES }
  validate :not_a_hosted_domain

  def verified? = status == STATUS_VERIFIED

  def required_records
    selector = DkimKey.selector
    mail_domain = DnsRecordsSerializer::MAIL_DOMAIN
    [
      { type: "CNAME", host: "#{selector}._domainkey.#{name}", value: "#{selector}._domainkey.#{mail_domain}", required: true },
      { type: "TXT", host: "_dmarc.#{name}", value: "v=DMARC1; p=quarantine; rua=mailto:dmarc@#{mail_domain}", required: false }
    ]
  end

  def check_dns!(resolver: DnsResolver.new)
    dkim, dmarc = required_records
    dkim_ok = resolver.cname(dkim[:host]).to_s.chomp(".").casecmp?(dkim[:value])
    dmarc_ok = resolver.txt(dmarc[:host]).any? { |t| t.strip.start_with?("v=DMARC1") }
    update!(dns_checks: { dkim: dkim_ok, dmarc: dmarc_ok }, dns_checked_at: Time.current,
      status: dkim_ok ? STATUS_VERIFIED : STATUS_PENDING_DNS)
    dkim_ok
  end

  # May this org send API mail from `host`? Returns nil when it may, else why not.
  def self.refusal_for(organization, host)
    hosted = organization.domains.find_by(name: host)
    if hosted
      return "#{host} is a sealed domain and cannot send through the API" if hosted.e2ee_enabled
      return nil if hosted.accepting_mail?

      return "#{host} is not verified yet"
    end
    send_only = where(organization: organization).find_by(name: host)
    return "#{host} is not one of this organization's domains" unless send_only

    send_only.verified? ? nil : "#{host} is not verified yet"
  end

  private

  def not_a_hosted_domain
    errors.add(:name, "is already a hosted domain") if ::Domain.exists?(name: name)
  end
end
