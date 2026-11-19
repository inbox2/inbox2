module MailImporter
  # Gmail through the service account's domain-wide delegation: each mailbox is
  # read as its user (gmail.readonly), the directory as the admin who connected
  # Google. The first run lists every message outside Spam, Trash, Drafts and
  # Chats; the cursor then holds the mailbox's historyId, so a re-run (the
  # catch-up after the MX flip) reads only messages added since.
  #
  # Cursor: {"history" => id, "page" => token} while listing; {"history" => id,
  # "done" => true} after, read through history.list.
  class Google < Disk::Importer::Google
    include MailImporter

    GMAIL = "https://gmail.googleapis.com/gmail/v1/users/me".freeze
    SCOPE = "https://www.googleapis.com/auth/gmail.readonly".freeze
    DIRECTORY_SCOPE = "https://www.googleapis.com/auth/admin.directory.user.readonly".freeze
    QUERY = "-in:drafts -in:chats".freeze # spam and trash are left out by default
    SKIP_LABELS = { "SPAM" => "In Spam", "TRASH" => "In Trash", "DRAFT" => "A draft", "CHAT" => "A chat" }.freeze

    def directory
      @directory_token = as(connection.account_email, DIRECTORY_SCOPE)[0]
      paged("#{at(:directory)}?customer=my_customer&maxResults=500", "users")
        .reject { |u| u["suspended"] }.map { |u| [u["primaryEmail"], u.dig("name", "fullName")] }
    ensure
      @directory_token = nil
    end

    def each_message(cursor, &)
      state = cursor.present? ? JSON.parse(cursor) : {}
      return history(state["history"], &) if state["done"]

      start = state["history"] || get_json("#{at(:gmail)}/profile")["historyId"]
      page = state["page"]
      loop do
        url = "#{at(:gmail)}/messages?maxResults=500&q=#{CGI.escape(QUERY)}"
        url += "&pageToken=#{CGI.escape(page)}" if page
        body = get_json(url)
        here = { "history" => start, "page" => page }.compact.to_json
        body.fetch("messages", []).each { |m| yield source(m["id"], here) }
        page = body["nextPageToken"] or break
      end
      { "history" => start, "done" => true }.to_json
    end

    def raw(src) = src.payload

    # The mailbox is read as its user, never cached on the shared connection.
    def token
      return @directory_token if @directory_token

      @delegated = nil if @delegated && @delegated[1] < 1.minute.from_now
      @delegated ||= as(import.source_email, SCOPE)
      @delegated[0]
    end

    private

    # Google answers a missing or narrower delegation with 401 unauthorized_client,
    # which the base reads as a revoked connection; say what to fix instead.
    def as(subject, scope)
      delegated(subject, scope)
    rescue Stop => e
      raise unless e.reason == Disk::Import::PAUSE_AUTHORIZATION

      raise Stop.new(e.reason, "Google refused domain-wide access for #{subject}. In the Google Workspace admin console, " \
                               "the service account's delegation must list #{scope}.")
    end

    # Messages added since `start`. A historyId Gmail no longer keeps (404,
    # about a week) falls back to listing everything again; what is already
    # here comes back as duplicates.
    def history(start, &)
      latest = start
      page = nil
      here = { "history" => start, "done" => true }.to_json
      loop do
        url = "#{at(:gmail)}/history?startHistoryId=#{CGI.escape(start.to_s)}&historyTypes=messageAdded&maxResults=500"
        url += "&pageToken=#{CGI.escape(page)}" if page
        res = request(:get, url)
        return each_message(nil, &) if res.status == 404
        raise ItemFailed, "Gmail answered #{res.status}: #{error_of(res)}" unless res.ok?

        latest = res.json["historyId"] || latest
        Array(res.json["history"]).flat_map { |h| Array(h["messagesAdded"]) }
          .each { |a| yield source(a.dig("message", "id"), here) }
        page = res.json["nextPageToken"] or break
      end
      { "history" => latest, "done" => true }.to_json
    end

    # The mailbox's own labels, id => name (Gmail's system labels are left out).
    def user_labels
      @user_labels ||= get_json("#{at(:gmail)}/labels").fetch("labels", [])
        .select { |l| l["type"] == "user" }.to_h { |l| [l["id"], l["name"]] }
    end

    def source(id, cursor)
      res = request(:get, "#{at(:gmail)}/messages/#{CGI.escape(id)}?format=raw")
      return Source.new(id: id, cursor: cursor, skip: "Deleted at the source") if res.status == 404
      return Source.new(id: id, cursor: cursor, error: "Gmail answered #{res.status}: #{error_of(res)}") unless res.ok?

      m = res.json
      labels = Array(m["labelIds"])
      skip = SKIP_LABELS.values_at(*labels).compact.first
      Source.new(id: id, thread_id: m["threadId"], cursor: cursor, skip: skip,
                 labels: labels.filter_map { |l| l == "STARRED" ? "Starred" : user_labels[l] },
                 status: labels.include?("INBOX") ? Conversation::STATUS_OPEN : Conversation::STATUS_ARCHIVED,
                 read: !labels.include?("UNREAD"), sent: labels.include?("SENT"),
                 payload: skip ? nil : Base64.urlsafe_decode64(m["raw"].to_s))
    end
  end
end
