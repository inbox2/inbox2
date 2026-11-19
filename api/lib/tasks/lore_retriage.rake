# Re-run the one-time Lore re-triage for one org (docs/Triage.md "Upgrade
# re-triage"), even when it already ran: bin/rails "lore:retriage[org_xxx]"
namespace :lore do
  desc "Re-triage an org's open threads still carrying a pre-2026-10-20 label"
  task :retriage, %i[org_key] => :environment do |_, args|
    org = Organization.find_by!(key: args[:org_key])
    n = LoreRetriageJob.scope(org).count
    LoreRetriageJob.perform_now(org.id, true)
    puts "[lore:retriage] #{org.key}: #{n} threads queued"
  end
end
