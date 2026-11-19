require "digest"
require "tempfile"

module MailImporter
  # A Google Takeout mail export (the "All mail Including Spam and Trash.mbox"
  # file) instead of the Gmail API: no service account, no delegation, the
  # person exports their own mailbox and an operator feeds the file in
  # (`rake mail_import:takeout`). Gmail writes its state into each message as
  # headers, X-GM-THRID (the thread) and X-Gmail-Labels (folders, read state,
  # the person's labels), which map the same way the API importer maps
  # labelIds.
  #
  # The file is a path (the rake task) or, without one, the import's Disk file
  # (a person's own import from Settings › Account), copied to a temp file for
  # the run.
  #
  # Cursor: the byte offset of the next message in the file, so a stopped run
  # resumes where it was; re-reading from any earlier offset meets duplicates.
  # From Disk it is "<version id>:<offset>", so a file replaced since starts over
  # at 0 instead of reading the new bytes from the old offset.
  class Takeout
    include MailImporter

    SKIP_LABELS = { "Spam" => "In Spam", "Trash" => "In Trash", "Drafts" => "A draft", "Draft" => "A draft",
                    "Chat" => "A chat", "Chats" => "A chat" }.freeze
    # Gmail's own labels; anything else (bar the prefixes) is the person's.
    SYSTEM_LABELS = %w[Inbox Unread Opened Sent Archived Important Starred].freeze
    SYSTEM_PREFIXES = ["Category ", "IMAP_"].freeze
    SEPARATOR = "From ".b

    attr_reader :import

    def initialize(import, path = nil)
      @import = import
      @path = path
    end

    def each_message(cursor, &)
      return read(@path, cursor, &) if @path

      # Its owner must still see the file when the job runs, not only when it was queued.
      node = import.source_node if import.source_node && Disk::Access.scope_for(import.owner).exists?(id: import.source_node_id)
      version = node&.current_version or raise Disk::Importer::Stop.new(MailImport::PAUSE_ERROR, "The .mbox file is no longer on Disk.")
      raise Disk::Importer::Stop.new(MailImport::PAUSE_ERROR, "You can't import a sealed file.") if version.sealed?

      pinned, offset = cursor.to_s.split(":", 2)
      @prefix = "#{version.id}:"
      Tempfile.create(["mail-import", ".mbox"], binmode: true) do |tmp|
        Disk::Storage.current.read_into(version.storage_key, tmp)
        tmp.flush
        @prefix + read(tmp.path, pinned == version.id.to_s ? offset : 0, &)
      end
    end

    def raw(src) = src.payload

    private

    def read(path, cursor)
      File.open(path, "rb") do |f|
        f.seek(cursor.to_i)
        start = nil
        lines = []
        f.each_line do |line|
          if line.start_with?(SEPARATOR)
            yield source(lines.join, start) if start
            start = f.pos - line.bytesize
            lines = []
          else
            # mboxrd: Gmail quotes a body line starting "From " as ">From ".
            lines << (line.match?(/\A>+From /n) ? line.byteslice(1..) : line)
          end
        end
        yield source(lines.join, start) if start
        f.pos.to_s
      end
    end

    def source(raw, offset)
      head = raw[/\A.*?(?=\r?\n\r?\n)/m].to_s.gsub(/\r?\n[ \t]+/, " ")
      labels = parse_labels(head[/^X-Gmail-Labels:[ \t]*(.*)$/i, 1])
      skip = SKIP_LABELS.values_at(*labels).compact.first
      Source.new(id: Digest::SHA256.hexdigest(raw)[0, 32], thread_id: head[/^X-GM-THRID:[ \t]*(\d+)/i, 1],
                 cursor: "#{@prefix}#{offset}", skip: skip,
                 labels: labels.filter_map { |l| l == "Starred" ? "Starred" : (l unless system?(l)) },
                 status: labels.include?("Inbox") ? Conversation::STATUS_OPEN : Conversation::STATUS_ARCHIVED,
                 read: !labels.include?("Unread"), sent: labels.include?("Sent"),
                 payload: skip ? nil : raw)
    end

    def system?(label)
      SYSTEM_LABELS.include?(label) || SKIP_LABELS.key?(label) || SYSTEM_PREFIXES.any? { |p| label.start_with?(p) }
    end

    # A comma list; a label holding a comma comes quoted.
    def parse_labels(value)
      value.to_s.force_encoding(Encoding::UTF_8).scrub("").scan(/\s*"((?:[^"]|"")*)"|([^,]+)/)
        .map { |quoted, bare| quoted ? quoted.gsub('""', '"') : bare.strip }.compact_blank
    end
  end
end
