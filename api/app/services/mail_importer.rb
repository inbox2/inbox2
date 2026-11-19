require "mail"

# Admin-driven mail import from Google Workspace or Microsoft 365 into a
# member's private MX history (docs/plans/mail-import.md). The adapters
# (MailImporter::Google, ::Microsoft) subclass the Disk importers for their
# source plumbing: the service-account / client-credentials tokens, the
# tenant-wide throttle hold, Stop and the HTTP transport specs swap out. This
# module replaces Disk's run loop; MailImporter::Writer stores each message.
#
# An adapter implements:
#   directory                     [[email, name]] for every active source user
#   each_message(cursor) { |src| } every Source from cursor; returns the cursor
#                                 the next run starts from (a change token)
#   raw(src)                      the message's RFC 5322 bytes
module MailImporter
  # status: Conversation::STATUS_OPEN (in the inbox) or _ARCHIVED; sent: the
  # owner sent it; skip: a reason it is not imported (spam, trash, draft);
  # error: why fetching it failed (reported); cursor: a safe checkpoint
  # (re-processing from it only meets duplicates); payload: the raw bytes when
  # the listing already carried them; labels: the owner's own way of filing it
  # (Gmail labels, Outlook folders and categories), stored as private labels.
  Source = Struct.new(:id, :thread_id, :status, :read, :sent, :skip, :error, :cursor, :payload, :labels,
                      keyword_init: true)

  REPORT_MAX = 500 # failed items kept in the report

  def self.for(import)
    return MailImporter::Takeout.new(import) if import.provider == MailImport::TAKEOUT

    { OauthProvider::GOOGLE => MailImporter::Google, OauthProvider::MICROSOFT => MailImporter::Microsoft }
      .fetch(import.provider).new(import)
  end

  def run
    @counts = import.counts.to_h
    @report = import.report.to_h
    writer = Writer.new(import)
    final = each_message(import.cursor) do |src|
      # Stopped, or stopped and started again (a newer run owns the row now).
      state, run = MailImport.where(id: import.id).pick(:state, :run)
      raise Disk::Importer::Cancelled if state == MailImport::STATE_CANCELLED || run != import.run

      handle(src, writer)
      checkpoint!(src.cursor)
    end
    live.update_all(state: MailImport::STATE_DONE, cursor: final, counts: @counts, report: @report,
                    finished_at: Time.current, pause_reason: nil, error: nil, updated_at: Time.current)
  rescue Disk::Importer::Cancelled
    mine.update_all(counts: @counts, report: @report, updated_at: Time.current)
  rescue Disk::Importer::Throttled => e
    checkpoint!(nil)
    queued = live.update_all(state: MailImport::STATE_QUEUED, updated_at: Time.current)
    MailImportJob.set(wait: e.wait.seconds).perform_later(import.id) if queued == 1
  rescue Disk::Importer::Stop => e
    live.update_all(state: MailImport::STATE_PAUSED, pause_reason: e.reason, error: e.message,
                    counts: @counts, report: @report, updated_at: Time.current)
  end

  private

  def handle(src, writer)
    bump("seen")
    return bump("skipped") if src.skip
    raise Disk::Importer::ItemFailed, src.error if src.error

    bump(writer.write(raw(src), source_id: src.id, thread_id: src.thread_id, status: src.status,
                                read: src.read, sent: src.sent, labels: Array(src.labels)).to_s)
  # This message only; anything else (storage, the database) pauses the run.
  rescue Disk::Importer::ItemFailed, Disk::Importer::Http::Incomplete, Mail::Field::ParseError,
         ArgumentError, EncodingError, ActiveRecord::RecordInvalid => e
    bump("failed")
    failed = (@report["failed"] ||= [])
    failed << { "id" => src.id, "reason" => e.message.truncate(300) } if failed.size < REPORT_MAX
  end

  def bump(key) = @counts[key] = @counts[key].to_i + 1

  def checkpoint!(cursor)
    attrs = { counts: @counts, report: @report, updated_at: Time.current }
    attrs[:cursor] = cursor if cursor
    mine.update_all(attrs)
  end

  # The row while this run still owns it; a newer run makes every write a no-op.
  def mine = MailImport.where(id: import.id, run: import.run)
  # Still running as well: a Stop that lands after the last check keeps the row cancelled.
  def live = mine.where(state: MailImport::STATE_RUNNING)
end
