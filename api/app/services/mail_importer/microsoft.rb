module MailImporter
  # Exchange Online through Microsoft Graph with the importer app's application
  # permission Mail.Read (tenant admin consent; the connection is the importer's
  # org-reach one). Every folder outside Junk, Deleted Items, Drafts, Outbox and
  # Conversation History is read through messages/delta; the cursor keeps each
  # folder's delta link, so a re-run reads only what changed since. A folder of
  # the person's own (not Inbox, Sent Items or Archive) becomes a private label
  # named by its path, as do categories and the Flagged state.
  #
  # Cursor: {"delta" => {folder id => delta link}, "done" => [folder ids read
  # this run], "current" => folder id, "next" => the page being read}.
  class Microsoft < Disk::Importer::Microsoft
    include MailImporter

    SKIP_FOLDERS = %w[junkemail deleteditems drafts outbox conversationhistory].freeze
    SELECT = "id,conversationId,isRead,isDraft,categories,flag".freeze
    UNLABELLED = %w[inbox sentitems archive].freeze

    def directory
      paged("#{at(:graph)}/users?$select=mail,userPrincipalName,displayName,accountEnabled&$top=999")
        .reject { |u| u["accountEnabled"] == false }
        .map { |u| [u["mail"].presence || u["userPrincipalName"], u["displayName"]] }
    end

    def each_message(cursor, &)
      state = cursor.present? ? JSON.parse(cursor) : {}
      delta = state["delta"] || {}
      done = state["done"] || []
      folders.each do |fid, folder_label|
        next if done.include?(fid)

        fresh = "#{mailbox}/mailFolders/#{fid}/messages/delta?$select=#{SELECT}"
        url = (state["current"] == fid && state["next"]) || delta[fid] || fresh
        loop do
          here = { "delta" => delta, "done" => done, "current" => fid, "next" => url }.to_json
          res = request(:get, graph_link!(url), headers: { "Prefer" => "odata.maxpagesize=100" })
          # An expired delta link: read the folder again from the start; what
          # is already here comes back as duplicates.
          if res.status == 410 && url != fresh
            url = fresh
            next
          end
          raise ItemFailed, "#{label} answered #{res.status}: #{error_of(res)}" unless res.ok?

          res.json.fetch("value", []).each { |m| yield source(m, fid, folder_label, here) unless m.key?("@removed") }
          url = res.json["@odata.nextLink"] and next
          delta[fid] = res.json["@odata.deltaLink"]
          break
        end
        done << fid
      end
      { "delta" => delta }.to_json
    end

    def raw(src)
      res = request(:get, "#{mailbox}/messages/#{CGI.escape(src.id)}/$value")
      raise ItemFailed, "#{label} answered #{res.status}: #{error_of(res)}" unless res.ok?

      res.body
    end

    private

    def mailbox = "#{at(:graph)}/users/#{CGI.escape(import.source_email)}"

    def source(m, fid, folder_label, cursor)
      labels = [folder_label, *Array(m["categories"])]
      labels << "Flagged" if m.dig("flag", "flagStatus") == "flagged"
      Source.new(id: m["id"], thread_id: m["conversationId"], cursor: cursor, labels: labels.compact,
                 skip: m["isDraft"] ? "A draft" : nil,
                 status: fid == well_known["inbox"] ? Conversation::STATUS_OPEN : Conversation::STATUS_ARCHIVED,
                 read: m["isRead"] != false, sent: fid == well_known["sentitems"])
    end

    # [folder id, label] for every folder to read, child folders included,
    # skipping the skipped folders' whole subtrees. The label is the path of the
    # person's own folders under the top (Inbox/Clients/Acme => "Clients/Acme").
    def folders
      skip = SKIP_FOLDERS.filter_map { |n| well_known[n] }
      plain = UNLABELLED.filter_map { |n| well_known[n] }
      walk = lambda do |url, prefix|
        paged(url).flat_map do |f|
          next [] if skip.include?(f["id"])

          label = plain.include?(f["id"]) ? nil : [prefix, f["displayName"]].compact.join("/").presence
          kids = f["childFolderCount"].to_i.positive? ? walk.("#{mailbox}/mailFolders/#{f['id']}/childFolders?$top=100", label) : []
          [[f["id"], label], *kids]
        end
      end
      walk.("#{mailbox}/mailFolders?$top=100", nil)
    end

    # Well-known folder name => id; a mailbox without one (no Conversation
    # History) leaves it out.
    def well_known
      @well_known ||= (SKIP_FOLDERS + UNLABELLED).each_with_object({}) do |name, out|
        res = request(:get, "#{mailbox}/mailFolders/#{name}?$select=id")
        out[name] = res.json["id"] if res.ok?
      end
    end
  end
end
