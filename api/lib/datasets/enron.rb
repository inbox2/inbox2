require_relative "base"

module Datasets
  class Enron < Base
    # The Enron corpus: ~500K emails from ~150 employees.
    # Public domain, released by FERC, hosted by CMU.
    # Maildir format: each email is a separate text file under user/folder/ dirs.

    class << self
      def slug = "enron"
      def display_name = "Enron Email Corpus"
      def description = "~500K emails from Enron employees (2000-2002). Public domain, released by FERC."
      def url = "https://www.cs.cmu.edu/~enron/enron_mail_20150507.tar.gz"
      def approximate_count = 500_000
    end

    protected

    def archive_path
      download_path.join("enron_mail_20150507.tar.gz")
    end

    def import
      # The extracted structure is: maildir/<username>/<folder>/<files>
      maildir = find_maildir

      unless maildir
        puts "  ERROR: Could not find maildir directory in extracted archive."
        puts "  Expected structure: .../maildir/<username>/<folder>/<email_files>"
        return
      end

      puts "  Found maildir at: #{maildir}"

      # Group emails into conversations by threading (In-Reply-To / References)
      # For speed, we process each user's folders and thread by subject
      users = maildir.children.select(&:directory?).sort_by(&:basename)
      puts "  Found #{users.size} user mailboxes"

      thread_pool = {}  # subject -> [emails]
      imported = 0

      users.each_with_index do |user_dir, ui|
        break if limit_reached?

        username = user_dir.basename.to_s
        email_files = collect_email_files(user_dir)

        email_files.each do |file|
          break if limit_reached?

          parsed = parse_email_file(file)
          next unless parsed
          next if parsed[:subject].blank? && parsed[:body_plain].blank?

          # Thread by normalized subject
          norm_subject = normalize_subject(parsed[:subject] || "(no subject)")
          thread_pool[norm_subject] ||= []
          thread_pool[norm_subject] << parsed

          # Import in batches: when a thread reaches a natural size or pool gets big
          if thread_pool.size >= @batch_size
            flush_threads(thread_pool)
            thread_pool.clear
          end
        end

        # Progress
        if (ui + 1) % 10 == 0 || ui == users.size - 1
          print "\r  Processed #{ui + 1}/#{users.size} mailboxes, #{@stats[:conversations]} conversations so far"
        end
      end

      # Flush remaining
      flush_threads(thread_pool) unless thread_pool.empty?
      puts ""
    end

    private

    def find_maildir
      # Look for the maildir directory anywhere in the extracted tree
      candidates = Dir.glob(extract_path.join("**/maildir")).select { |p| File.directory?(p) }
      candidates.first ? Pathname.new(candidates.first) : nil
    end

    def collect_email_files(user_dir)
      Dir.glob(user_dir.join("**/*"))
        .select { |f| File.file?(f) }
        .map { |f| Pathname.new(f) }
    end

    def normalize_subject(subject)
      SubjectNormalizer.normalize(subject).downcase.truncate(200)
    end

    def flush_threads(threads)
      threads.each do |_subject, emails|
        break if limit_reached?

        # Sort by date within thread
        emails.sort_by! { |e| e[:date] || DateTime.new(2001) }

        # Mark as spam ~2% of the time for realism
        status = rand < 0.02 ? Conversation::STATUS_SPAM : nil

        import_conversation(emails, status: status)
      end
    end
  end
end
