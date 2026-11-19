require_relative "base"

module Datasets
  class SpamAssassin < Base
    # Apache SpamAssassin public mail corpus.
    # Contains ham (legitimate) and spam emails, useful for testing spam filtering.
    # Multiple archives available — we grab the combined set.

    ARCHIVES = {
      "easy_ham" => "https://spamassassin.apache.org/old/publiccorpus/20030228_easy_ham.tar.bz2",
      "easy_ham_2" => "https://spamassassin.apache.org/old/publiccorpus/20030228_easy_ham_2.tar.bz2",
      "hard_ham" => "https://spamassassin.apache.org/old/publiccorpus/20030228_hard_ham.tar.bz2",
      "spam" => "https://spamassassin.apache.org/old/publiccorpus/20030228_spam.tar.bz2",
      "spam_2" => "https://spamassassin.apache.org/old/publiccorpus/20030228_spam_2.tar.bz2"
    }.freeze

    class << self
      def slug = "spamassassin"
      def display_name = "SpamAssassin Public Corpus"
      def description = "~6K ham + spam emails from Apache SpamAssassin project. Great for spam filter testing."
      def url = "https://spamassassin.apache.org/old/publiccorpus/"
      def approximate_count = 6_000
    end

    protected

    def archive_path
      # We have multiple archives, check if first one exists
      download_path.join("20030228_easy_ham.tar.bz2")
    end

    def downloaded?
      ARCHIVES.keys.all? { |name| download_path.join("#{name}.tar.bz2").exist? }
    end

    def download
      ARCHIVES.each do |name, archive_url|
        dest = download_path.join("#{name}.tar.bz2")
        next if dest.exist?
        download_single(name, archive_url, dest)
      end
    end

    def download_single(name, archive_url, dest)
      puts "Downloading #{name}..."
      uri = URI(archive_url)

      5.times do
        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
          request = Net::HTTP::Get.new(uri)
          http.request(request) do |resp|
            case resp
            when Net::HTTPRedirection
              uri = URI(resp["location"])
              next
            when Net::HTTPSuccess
              total = resp.content_length
              downloaded = 0
              File.open(dest, "wb") do |f|
                resp.read_body do |chunk|
                  f.write(chunk)
                  downloaded += chunk.size
                  if total
                    pct = (downloaded * 100.0 / total).round(1)
                    print "\r  #{name}: #{human_size(downloaded)} / #{human_size(total)} (#{pct}%)"
                  else
                    print "\r  #{name}: #{human_size(downloaded)}"
                  end
                end
              end
              puts ""
              return
            else
              raise "Download failed: #{resp.code} #{resp.message}"
            end
          end
        end
      end
    end

    def extract
      FileUtils.mkdir_p(extract_path)
      ARCHIVES.each_key do |name|
        archive = download_path.join("#{name}.tar.bz2")
        next unless archive.exist?
        puts "  Extracting #{name}..."
        system("tar", "xjf", archive.to_s, "-C", extract_path.to_s, exception: true)
      end
      puts "  Extraction complete."
    end

    def import
      # Directories: easy_ham, easy_ham_2, hard_ham, spam, spam_2
      ham_dirs = %w[easy_ham easy_ham_2 hard_ham]
      spam_dirs = %w[spam spam_2]

      # Import ham emails
      ham_dirs.each do |dir_name|
        dir = find_dir(dir_name)
        next unless dir

        import_directory(dir, is_spam: false)
        break if limit_reached?
      end

      # Import spam emails
      spam_dirs.each do |dir_name|
        dir = find_dir(dir_name)
        next unless dir

        import_directory(dir, is_spam: true)
        break if limit_reached?
      end
    end

    private

    def find_dir(name)
      candidates = Dir.glob(extract_path.join("**/#{name}")).select { |p| File.directory?(p) }
      candidates.first ? Pathname.new(candidates.first) : nil
    end

    def import_directory(dir, is_spam:)
      files = dir.children.select(&:file?).reject { |f| f.basename.to_s == "cmds" }
      label = is_spam ? "spam" : "ham"
      puts "  Importing #{files.size} #{label} emails from #{dir.basename}..."

      files.each_with_index do |file, i|
        break if limit_reached?

        parsed = parse_email_file(file)
        next unless parsed
        next if parsed[:body_plain].blank? && parsed[:body_html].blank?
        @stats[:skipped] += 1 and next if parsed[:subject].blank?

        status = is_spam ? Conversation::STATUS_SPAM : Conversation::STATUS_OPEN

        import_conversation([ parsed ], status: status)

        if (i + 1) % 200 == 0
          print "\r    #{i + 1}/#{files.size} (#{@stats[:conversations]} total conversations)"
        end
      end
      puts ""
    end
  end
end
