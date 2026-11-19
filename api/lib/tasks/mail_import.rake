# Google Takeout mail into a member's private MX history (docs/plans/mail-import.md,
# "Takeout"). The mailbox must exist on an MX domain; its member owns the import.
#
#   pl cp "All mail Including Spam and Trash.mbox" api:/tmp/mail.mbox --production
#   pl exec api --production -- inbox2-run bin/rails "mail_import:takeout[/tmp/mail.mbox,ana@lalaaji.com]"
#
# Re-running with the same file resumes from where it stopped; a finished import
# given a newer export reads the whole file again and stores only what is new.
namespace :mail_import do
  desc "Import a Google Takeout .mbox into a mailbox's private history"
  task :takeout, %i[path address] => :environment do |_, args|
    path, address = args[:path].to_s, args[:address].to_s.downcase.strip
    abort "usage: rake 'mail_import:takeout[/path/to/file.mbox,person@domain]'" if path.empty? || address.empty?
    abort "No file at #{path}" unless File.file?(path)

    local, host = address.split("@", 2)
    mailbox = Mailbox.joins(:domain).where("lower(domains.name) = ?", host).find_by("lower(mailboxes.local_part) = ?", local) or
      abort "No mailbox #{address} on an inbox2 domain; create it first"
    owner = mailbox.membership
    import = MailImport.find_or_initialize_by(organization: owner.organization, provider: MailImport::TAKEOUT, source_email: address)
    import.cursor = nil if import.done? # a new export: read it all, duplicates are skipped
    if import.persisted? && import.owner_membership_id != owner.id # the address changed hands
      import.threads.delete_all
      import.cursor = nil
    end
    import.update!(membership: owner, owner: owner, domain: mailbox.domain, state: MailImport::STATE_RUNNING, run: import.run + 1,
                   started_at: import.started_at || Time.current, pause_reason: nil, error: nil)

    progress = Thread.new do
      loop do
        sleep 10
        puts "#{address}: #{MailImport.find(import.id).counts.to_h}"
      end
    end
    MailImporter::Takeout.new(import, path).run
    progress.kill
    import.reload
    puts "#{address}: #{import.state} #{import.counts.to_h}#{" (#{import.error})" if import.error}"
    Array(import.report.to_h["failed"]).first(20).each { |f| puts "  failed #{f["id"]}: #{f["reason"]}" }
  end
end
