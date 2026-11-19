require "net/http"
require "uri"
require "fileutils"
require "open3"

module Datasets
  class Base
    DOWNLOAD_DIR = Rails.root.join("tmp", "datasets")

    class << self
      def slug
        raise NotImplementedError
      end

      def display_name
        raise NotImplementedError
      end

      def description
        raise NotImplementedError
      end

      def url
        raise NotImplementedError
      end

      def approximate_count
        raise NotImplementedError
      end
    end

    def initialize(organization:, limit: nil, batch_size: 1000)
      @organization = organization
      @limit = limit
      @batch_size = batch_size
      @stats = { conversations: 0, messages: 0, skipped: 0, errors: 0 }
    end

    def load!
      ensure_download_dir
      download unless downloaded?
      extract unless extracted?
      puts "Importing #{self.class.display_name}#{@limit ? " (limit: #{@limit})" : ""}..."
      import
      print_stats
      @stats
    end

    def purge!
      count = Conversation.where(organization: @organization)
        .where("subject LIKE ?", "[#{self.class.slug}]%")
        .destroy_all
        .count
      puts "Purged #{count} conversations from #{self.class.display_name}"
      count
    end

    protected

    def import
      raise NotImplementedError
    end

    def download_path
      DOWNLOAD_DIR.join(self.class.slug)
    end

    def archive_path
      raise NotImplementedError
    end

    def extract_path
      download_path.join("extracted")
    end

    def downloaded?
      archive_path.exist?
    end

    def extracted?
      extract_path.exist? && extract_path.children.any?
    end

    def ensure_download_dir
      FileUtils.mkdir_p(download_path)
    end

    def download
      puts "Downloading #{self.class.display_name} from #{self.class.url}..."
      uri = URI(self.class.url)

      # Follow redirects (up to 5)
      5.times do
        response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
          request = Net::HTTP::Get.new(uri)
          http.request(request) do |resp|
            case resp
            when Net::HTTPRedirection
              uri = URI(resp["location"])
              next resp
            when Net::HTTPSuccess
              total = resp.content_length
              downloaded = 0
              File.open(archive_path, "wb") do |f|
                resp.read_body do |chunk|
                  f.write(chunk)
                  downloaded += chunk.size
                  if total
                    pct = (downloaded * 100.0 / total).round(1)
                    print "\r  #{human_size(downloaded)} / #{human_size(total)} (#{pct}%)"
                  else
                    print "\r  #{human_size(downloaded)}"
                  end
                end
              end
              puts "\n  Download complete."
              return
            else
              raise "Download failed: #{resp.code} #{resp.message}"
            end
          end
        end
      end
      raise "Too many redirects"
    end

    def extract
      puts "Extracting #{archive_path.basename}..."
      FileUtils.mkdir_p(extract_path)

      ext = archive_path.to_s
      if ext.end_with?(".tar.gz", ".tgz")
        system("tar", "xzf", archive_path.to_s, "-C", extract_path.to_s, exception: true)
      elsif ext.end_with?(".tar.bz2")
        system("tar", "xjf", archive_path.to_s, "-C", extract_path.to_s, exception: true)
      elsif ext.end_with?(".zip")
        system("unzip", "-qo", archive_path.to_s, "-d", extract_path.to_s, exception: true)
      else
        raise "Unknown archive format: #{archive_path.basename}"
      end
      puts "  Extraction complete."
    end

    # Build a conversation from one or more parsed email hashes.
    # Each email hash: { from:, to:, cc:, subject:, body_plain:, body_html:, date:, message_id:, in_reply_to:, references: }
    def import_conversation(emails, tags: [], status: nil)
      return if emails.empty?
      first = emails.first

      subject = "[#{self.class.slug}] #{first[:subject] || '(no subject)'}"
      from_addr = first[:from] || "unknown@unknown.com"
      to_addr = first[:to] || "unknown@unknown.com"

      conv = Conversation.find_or_create_by!(
        organization: @organization,
        subject: subject
      ) do |c|
        c.from_address = from_addr
        c.to_address = to_addr
        c.status = status || Conversation::STATUS_OPEN
        c.snippet = (first[:body_plain] || "").truncate(200)
        c.read = [ true, false ].sample
      end

      emails.each do |email|
        body = email[:body_plain] || ""
        Message.find_or_create_by!(
          conversation: conv,
          organization: @organization,
          from_address: email[:from] || from_addr,
          body_plain: body.truncate(100_000)
        ) do |m|
          m.to_address = email[:to] || to_addr
          m.cc_address = email[:cc]
          m.subject = first[:subject]
          m.body_html = email[:body_html]
          m.is_inbound = true
          m.message_id_header = email[:message_id]
          m.in_reply_to = email[:in_reply_to]
          m.references_header = email[:references]
          m.content_type = email[:body_html] ? "text/html" : "text/plain"
          m.created_at = email[:date] if email[:date]
        end
      end

      @stats[:conversations] += 1
      @stats[:messages] += emails.size
      conv
    rescue => e
      @stats[:errors] += 1
      if @stats[:errors] <= 10
        puts "  Error importing conversation '#{first[:subject]&.truncate(60)}': #{e.message}"
      elsif @stats[:errors] == 11
        puts "  (suppressing further error messages)"
      end
    end

    def limit_reached?
      @limit && @stats[:conversations] >= @limit
    end

    def print_stats
      puts "\n#{self.class.display_name} import complete:"
      puts "  Conversations: #{@stats[:conversations]}"
      puts "  Messages:      #{@stats[:messages]}"
      puts "  Skipped:       #{@stats[:skipped]}"
      puts "  Errors:        #{@stats[:errors]}"
    end

    def human_size(bytes)
      units = %w[B KB MB GB]
      unit = 0
      size = bytes.to_f
      while size >= 1024 && unit < units.size - 1
        size /= 1024
        unit += 1
      end
      "#{size.round(1)} #{units[unit]}"
    end

    # Parse an RFC 2822 email file into a hash
    def parse_email_file(path)
      raw = File.read(path, encoding: "binary")
      raw.force_encoding("UTF-8")
      raw.encode!("UTF-8", invalid: :replace, undef: :replace, replace: "")

      mail = Mail.new(raw)

      {
        from: extract_address(mail.from),
        to: extract_address(mail.to),
        cc: extract_address(mail.cc),
        subject: mail.subject&.encode("UTF-8", invalid: :replace, undef: :replace, replace: ""),
        body_plain: extract_body(mail),
        body_html: extract_html_body(mail),
        date: mail.date&.to_datetime,
        message_id: mail.message_id,
        in_reply_to: mail.in_reply_to.is_a?(Array) ? mail.in_reply_to.first : mail.in_reply_to,
        references: Array(mail.references).join(" ")
      }
    rescue => e
      nil
    end

    private

    def extract_address(field)
      case field
      when Array then field.first
      when String then field
      else nil
      end
    end

    def extract_body(mail)
      if mail.multipart?
        part = mail.text_part || mail.parts.first
        part&.decoded&.encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
      else
        mail.body&.decoded&.encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
      end
    rescue => e
      mail.body&.to_s
    end

    def extract_html_body(mail)
      return nil unless mail.multipart?
      part = mail.html_part
      part&.decoded&.encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
    rescue => e
      nil
    end
  end
end
