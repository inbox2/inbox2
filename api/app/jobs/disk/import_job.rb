module Disk
  # Runs one import (spec F10). Claims the import by moving it from queued to
  # running, so a resume and a scheduled throttle retry never run it twice.
  # Errors that are not the source's or the quota's pause it with the message.
  class ImportJob < ApplicationJob
    queue_as :default

    def perform(import_id)
      claimed = Disk::Import.where(id: import_id, state: Disk::Import::STATE_QUEUED)
        .update_all(state: Disk::Import::STATE_RUNNING, updated_at: Time.current)
      return unless claimed == 1

      import = Disk::Import.find(import_id)
      import.update_columns(started_at: Time.current) unless import.started_at
      unless import.organization.disk_writable?
        return import.update!(state: Disk::Import::STATE_PAUSED, pause_reason: Disk::Import::PAUSE_ERROR,
                              error: "Disk is read-only on this organization's plan")
      end

      Disk::Importer.for(import).run
    rescue StandardError => e
      Rails.logger.error("[Disk::ImportJob] #{import_id}: #{e.class}: #{e.message}")
      Disk::Import.where(id: import_id, state: Disk::Import::STATE_RUNNING)
        .update_all(state: Disk::Import::STATE_PAUSED, pause_reason: Disk::Import::PAUSE_ERROR,
                    error: "The import stopped on an error: #{e.message.truncate(300)}", updated_at: Time.current)
    end
  end
end
