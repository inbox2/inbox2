# Periodic DNS verification for connected domains. Resolves each org's records,
# records the per-record map (for the admin health card), and flips status: MX
# correct → verified; MX missing → back to pending_dns (catches breakage). A
# `receiving_mail` org (actually flowing mail) keeps its status — only the
# inbound pipeline promotes/holds that — but its record map is still refreshed.
# Runs recurring (see config/recurring.yml) and on-demand via perform(org_id).
class DnsCheckJob < ApplicationJob
  queue_as :default

  def perform(domain_id = nil)
    scope = domain_id ? Domain.where(id: domain_id) : Domain.all
    scope.find_each do |domain|
      domain.record_dns_check!(DnsChecker.new(domain).call)
    rescue StandardError => e
      Rails.logger.warn("DnsCheckJob #{domain.key}: #{e.class}: #{e.message}")
    end
  end
end
