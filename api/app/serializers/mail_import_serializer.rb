# A mail import and its progress (docs/plans/mail-import.md). counts keys:
# seen, imported, duplicate, skipped, failed.
class MailImportSerializer < ApplicationSerializer
  attributes :provider, :source_email, :state, :pause_reason, :error, :counts, :created_at, :started_at, :finished_at

  attribute :domain do |i|
    i.domain.name
  end

  # Failed messages with the reason (at most MailImporter::REPORT_MAX).
  attribute :failed do |i|
    Array(i.report["failed"])
  end

  attribute :waiting_until do |i|
    i.connection&.waiting_until if i.queued?
  end

  attribute :resumable, &:resumable?

  # Share of the .mbox read so far (0..1), from the cursor's byte offset; only
  # for a person's own import from a Disk file, nil otherwise.
  attribute :progress do |i|
    version = i.source_node&.current_version
    next nil unless version&.size_bytes.to_i.positive?
    next 1.0 if i.done?

    pinned, offset = i.cursor.to_s.split(":", 2)
    pinned == version.id.to_s ? [offset.to_f / version.size_bytes, 1.0].min.round(3) : 0.0
  end

  one :owner, resource: Disk::MemberRefSerializer
end
