module Api
  module V1
    class SearchController < BaseController
      before_action :require_organization!

      # Scripts written without word delimiters. Postgres' text-search parser
      # splits on non-word characters, so a run of Han/Kana/Hangul with no
      # spaces becomes ONE token: to_tsvector('您的订单已发货') never matches a
      # query for '订单'. For these queries we substring-match instead.
      UNSEGMENTED_SCRIPT = /[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}]/

      # Text a suggestion may be drawn from. Kept byte-identical to the
      # expression behind index_conversations_on_search_terms_trgm — the planner
      # matches expression indexes syntactically, so any drift here turns the
      # suggestion lookup into a sequential scan. Snippets are deliberately out:
      # trigram-indexing full body text costs far more than it buys for typos,
      # which are nearly always a subject word or a sender name.
      SUGGEST_TEXT = "(COALESCE(conversations.subject, '') || ' ' || COALESCE(conversations.from_address, ''))"
      # Below this trigram similarity a "correction" is just a different word.
      SUGGEST_MIN_SIMILARITY = 0.4

      # spec 6.3.1-6.3.3, A10.6
      def index
        # NFC so a query typed on macOS (which hands over decomposed forms)
        # matches text stored in the precomposed form senders actually transmit.
        query = params[:q].to_s.strip.unicode_normalize(:nfc)
        filters = filter_params

        # Filters alone are a valid search ("every PDF over 5MB"); only a request
        # with neither words nor filters has nothing to run.
        if query.blank? && filters.empty?
          return render json: ErrorSerializer.serialize("Search query required", status: 422), status: :unprocessable_content
        end

        scope = apply_filters(visible_conversations, filters)
        if query.present?
          # Both matchers return [sql, binds]: the query only ever reaches SQL as a bind.
          scope = scope.where(*(query.match?(UNSEGMENTED_SCRIPT) ? substring_match(query) : tsquery_match(query))) # nosemgrep: ruby.rails.security.injection.tainted-sql-string
        end

        rows = conversation_rows(scope.order(updated_at: :desc).limit(50))

        render json: {
          query: query,
          suggestion: query.present? && rows.empty? ? spelling_suggestion(query) : nil,
          conversations: rows,
          total: rows.length
        }
      end

      private

      # ── Structured filters (the Filters popover / search operators) ──
      # The client parses "from:ana larger:5mb" into these params (see the web
      # lib/searchQuery.js, which drives the local-channel half of the same
      # search); the values arrive already split out, never as raw SQL.

      # Folder scope. Absent means "everywhere except the bin": trash/spam hits
      # coming back after a delete read as a failed delete. Archived stays in.
      SCOPE_STATUSES = {
        "inbox" => [Conversation::STATUS_OPEN],
        "archive" => [Conversation::STATUS_ARCHIVED],
        "trash" => [Conversation::STATUS_TRASH],
        "spam" => [Conversation::STATUS_SPAM]
      }.freeze

      IS_FLAGS = %w[read unread urgent important attachment].freeze

      def filter_params
        params.permit(:from, :to, :cc, :subject, :filename, :type, :is, :in, :larger, :smaller, :after, :before)
          .to_h
          .select { |_, v| v.present? }
      end

      def apply_filters(scope, filters)
        scope = filter_addresses(scope, filters)
        scope = filter_attachments(scope, filters)
        scope = filter_flags(scope, filters)
        scope = filter_dates(scope, filters)
        filter_scope(scope, filters)
      end

      # from/to/cc match ANY message in the thread — a reply from the person you
      # searched for counts, which is what "mail from Ana" means to a reader.
      # ponytail: unanchored LIKE, no index. Revisit with a trigram index on the
      # address columns if a big org's search gets slow.
      def filter_addresses(scope, filters)
        { "from" => :from_address, "to" => :to_address, "cc" => :cc_address }.each do |key, column|
          next if filters[key].blank?
          scope = scope.where(id: message_ids_matching(column, split_values(filters[key])).select(:conversation_id))
        end
        if filters["subject"].present?
          scope = scope.where(any_ilike("conversations.subject", split_values(filters["subject"])))
        end
        scope
      end

      def filter_attachments(scope, filters)
        attachments = nil
        if filters["filename"].present?
          attachments = org_attachments.where(any_ilike("attachments.filename", split_values(filters["filename"])))
        end
        # "type:pdf" — the stored mime type is the better signal, but a file whose
        # type was never recorded is still findable by its extension.
        if filters["type"].present?
          extensions = split_values(filters["type"]).map { |t| t.delete_prefix(".") }
          mime, *mime_binds = any_ilike("attachments.content_type", extensions)
          name, *name_binds = any_ilike("attachments.filename", extensions.map { |e| ".#{e}" })
          attachments = (attachments || org_attachments)
            .where("(#{mime}) OR (#{name})", *mime_binds, *name_binds)
        end
        if filters["larger"].present?
          attachments = (attachments || org_attachments).where("attachments.size_bytes > ?", filters["larger"].to_i)
        end
        if filters["smaller"].present?
          attachments = (attachments || org_attachments).where("attachments.size_bytes < ?", filters["smaller"].to_i)
        end
        return scope if attachments.nil?

        scope.where(id: Message.where(id: attachments.select(:message_id)).select(:conversation_id))
      end

      def filter_flags(scope, filters)
        flags = split_values(filters["is"]).map(&:downcase) & IS_FLAGS
        scope = scope.where(read: true) if flags.include?("read")
        scope = scope.where(read: false) if flags.include?("unread")
        scope = with_tag(scope, Tag::TAG_URGENT) if flags.include?("urgent")
        scope = with_tag(scope, Tag::TAG_IMPORTANT) if flags.include?("important")
        if flags.include?("attachment")
          scope = scope.where(id: Message.where(id: org_attachments.select(:message_id)).select(:conversation_id))
        end
        scope
      end

      def filter_dates(scope, filters)
        scope = scope.where("conversations.updated_at >= ?", filters["after"]) if valid_date?(filters["after"])
        scope = scope.where("conversations.updated_at < ?", Date.parse(filters["before"]) + 1) if valid_date?(filters["before"])
        scope
      end

      def filter_scope(scope, filters)
        requested = filters["in"].to_s.downcase
        return scope if requested == "anywhere"

        statuses = SCOPE_STATUSES[requested]
        statuses ? scope.where(status: statuses) : scope.where.not(status: Conversation::DISCARDED_STATUSES)
      end

      def org_attachments
        Attachment.where(organization: current_organization)
      end

      def message_ids_matching(column, values)
        Message.where(organization: current_organization).readable_by(current_membership).where(any_ilike("messages.#{column}", values))
      end

      def with_tag(scope, name)
        scope.where(id: ConversationTag.joins(:tag)
          .where(tags: { organization: current_organization, name: name, membership_id: nil })
          .select(:conversation_id))
      end

      # OR of case-insensitive substring matches — values are bound, never
      # interpolated (E4), and the column name is ours, never the user's.
      def any_ilike(column, values)
        return "1=0" if values.empty?
        sql = Array.new(values.length, "#{column} ILIKE ?").join(" OR ")
        [sql, *values.map { |v| "%#{v}%" }]
      end

      def split_values(raw)
        raw.to_s.split(",").map(&:strip).reject(&:blank?)
      end

      def valid_date?(value)
        value.present? && value.to_s.match?(/\A\d{4}-\d{2}-\d{2}\z/)
      end

      # "Did you mean …?" — only computed when the query found nothing, so the
      # extra work lands on a search that was already a dead end. Returns the
      # query with each mistyped word swapped for its nearest neighbour in the
      # org's own mail, or nil when nothing is close enough. Unsegmented scripts
      # have no word boundaries to correct, so they're skipped.
      def spelling_suggestion(query)
        return nil if query.match?(UNSEGMENTED_SCRIPT)

        # Bare words only: 3+ alphanumerics, so websearch operators ("or", "-x")
        # and one-off initials aren't "corrected". Capped — a long query costs
        # one lookup per word.
        terms = query.scan(/[[:alnum:]]{3,}/).uniq.first(4)
        return nil if terms.empty?

        suggestion = terms.reduce(query) do |acc, term|
          better = closest_term(term)
          better ? acc.sub(/(?<![[:alnum:]])#{Regexp.escape(term)}(?![[:alnum:]])/i, better) : acc
        end
        suggestion == query ? nil : suggestion
      # A suggestion is a nicety; never let it take the search down with it
      # (e.g. a database where pg_trgm couldn't be installed).
      rescue ActiveRecord::StatementInvalid => e
        Rails.logger.warn("search suggestion failed: #{e.message}")
        nil
      end

      # Nearest word to `term` among the words of conversations this member can
      # see (E3: the trigram predicate rides on visible_conversations, so the
      # suggestion can't reveal a word from another org — or from a mailbox this
      # member is excluded from). `<%` is index-backed and pre-filters to rows
      # holding a similar word; `similarity` then ranks the words themselves.
      # nil when the corpus has nothing close, or only the typed word itself.
      def closest_term(term)
        rows = visible_conversations
          .where("? <% #{SUGGEST_TEXT}", term)
          .select(Arel.sql("DISTINCT unnest(regexp_split_to_array(lower(#{SUGGEST_TEXT}), '[^[:alnum:]]+')) AS w"))
          .limit(200)

        sql = ActiveRecord::Base.sanitize_sql_array([<<~SQL.squish, term, term, term])
          SELECT w FROM (#{rows.to_sql}) words
          WHERE length(w) >= 3 AND w <> lower(?) AND similarity(?, w) >= #{SUGGEST_MIN_SIMILARITY}
          ORDER BY similarity(?, w) DESC, length(w) LIMIT 1
        SQL

        # pg_trgm's `<%` prefilter defaults to a 0.6 word-similarity threshold —
        # stricter than the cut the ranking below applies, so it was throwing
        # away corrections that would have been accepted ("hssain" scores 0.571
        # against "Hussain", and never reached the ranking at all). Pin the two
        # to the same number: the prefilter's only job is to skip rows the
        # ranking would reject anyway. SET LOCAL, so it dies with the
        # transaction and can't leak into the connection's next checkout.
        Conversation.transaction do
          Conversation.connection.execute("SET LOCAL pg_trgm.word_similarity_threshold = #{SUGGEST_MIN_SIMILARITY}")
          Conversation.connection.select_value(sql)
        end
      end

      # websearch_to_tsquery supports `or`, quoted "phrases" and `-negation`,
      # defaults to AND between bare terms, and never raises on bad syntax.
      #
      # Match the conversation's own text (subject/snippet/from/to, maintained
      # by a trigger) OR an attachment filename on any of its messages, so a
      # search for a document name surfaces the mail that carried it. Filenames
      # are normalized (non-alphanumerics → spaces) before tsvector so
      # "Q3_report.pdf" tokenizes to q3/report/pdf and a search for "report"
      # hits it — [:alnum:] rather than a-zA-Z0-9, which erased every character
      # of a non-Latin filename ("الميزانية.pdf" indexed as just "pdf").
      # The subqueries are scoped to the org (E3 tenant isolation).
      #
      # Or any message's own vector — headers + body + attachment text, the
      # 'simple' config (Message::SEARCH_VECTOR_SQL). Drafts are left out: a
      # colleague's unsent draft in a shared thread must not surface by its words.
      def tsquery_match(query)
        [
          "conversations.search_vector @@ websearch_to_tsquery('english', :q) " \
          "OR conversations.id IN (" \
          "SELECT m.conversation_id FROM messages m " \
          "WHERE m.organization_id = :org AND NOT m.is_draft " \
          "AND m.search_vector @@ websearch_to_tsquery('simple', :q)) " \
          "OR conversations.id IN (" \
          "SELECT m.conversation_id FROM messages m " \
          "JOIN attachments a ON a.message_id = m.id " \
          "WHERE a.organization_id = :org AND " \
          "to_tsvector('english', regexp_replace(a.filename, :nonalnum, ' ', 'g')) " \
          "@@ websearch_to_tsquery('english', :q))",
          # Bound, not inlined: Rails reads the `:alnum:` inside a POSIX class as
          # a named bind placeholder and raises on the "missing" value.
          { q: query, org: current_organization.id, nonalnum: "[^[:alnum:]]+" }
        ]
      end

      # Substring fallback for unsegmented scripts — the same semantics the
      # local-channel clients get from their `LIKE %q%` search, so both halves
      # of a unified inbox behave alike for Chinese/Japanese/Korean.
      # ponytail: sequential scan (no trigram index). Add a pg_trgm GIN index on
      # subject/snippet if CJK search shows up in the slow-query log.
      def substring_match(query)
        [
          "conversations.subject ILIKE :like OR conversations.snippet ILIKE :like " \
          "OR conversations.from_address ILIKE :like OR conversations.to_address ILIKE :like " \
          "OR conversations.id IN (" \
          "SELECT m.conversation_id FROM messages m " \
          "JOIN attachments a ON a.message_id = m.id " \
          "WHERE a.organization_id = :org AND (a.filename ILIKE :like OR a.content_text ILIKE :like)) " \
          "OR conversations.id IN (" \
          "SELECT m.conversation_id FROM messages m " \
          "WHERE m.organization_id = :org AND NOT m.is_draft AND m.encryption_scheme = :plain " \
          "AND (m.body_plain ILIKE :like OR m.subject ILIKE :like))",
          { like: "%#{query.gsub(/[%_\\]/) { |c| "\\#{c}" }}%", org: current_organization.id,
            plain: Message::ENCRYPTION_SCHEME_NONE }
        ]
      end
    end
  end
end
