# Runs one mail import (docs/plans/mail-import.md). Claims it by moving it from
# queued to running and bumping run, so a resume and a scheduled throttle retry
# never run it twice, and a stopped job still busy can't write over the next
# run (MailImporter writes only while run is its own); an error that is not the
# source's pauses it with the message.
class MailImportJob < ApplicationJob
  queue_as :default

  def perform(import_id)
    claimed = MailImport.where(id: import_id, state: MailImport::STATE_QUEUED)
      .update_all(["state = ?, updated_at = ?, run = run + 1", MailImport::STATE_RUNNING, Time.current])
    return unless claimed == 1

    import = MailImport.find(import_id)
    run = import.run
    import.update_columns(started_at: Time.current) unless import.started_at
    MailImporter.for(import).run
  rescue StandardError => e
    Rails.logger.error("[MailImportJob] #{import_id}: #{e.class}: #{e.message}")
    MailImport.where(id: import_id, state: MailImport::STATE_RUNNING).where(run ? { run: run } : {})
      .update_all(state: MailImport::STATE_PAUSED, pause_reason: MailImport::PAUSE_ERROR,
                  error: "The import stopped on an error: #{e.message.truncate(300)}", updated_at: Time.current)
  end
end
