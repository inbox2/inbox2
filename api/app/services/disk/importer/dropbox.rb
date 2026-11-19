module Disk
  class Importer
    # Dropbox (API v2). A member's Dropbox into C:\; with a team admin's
    # grant, each member's home folder into their C:\ (acting as them through
    # Dropbox-API-Select-User) and each team folder into a share (as the admin,
    # Dropbox-API-Select-Admin, with Dropbox-API-Path-Root set to the
    # folder's namespace). list_folder recursive with list_folder/continue;
    # the cursor carries over, so a re-run reads only changes, and a reset
    # starts the listing again. Files verify against content_hash; files with
    # no bytes (Paper, Google files kept in Dropbox) go through files/export,
    # and Paper becomes a page when markdown is offered. The team's monthly
    # data transport cap stops the import with Dropbox's message.
    class Dropbox < Importer
      API = "https://api.dropboxapi.com/2".freeze
      CONTENT = "https://content.dropboxapi.com/2".freeze

      def self.identify(connection, tokens)
        headers = { "Authorization" => "Bearer #{tokens['access_token']}", "Content-Type" => "application/json" }
        if connection.org?
          res = Disk::Importer.transport.call(:post, "#{at(:api)}/team/token/get_authenticated_admin", headers: headers, body: "null")
          connection.account_email = res.json.dig("admin_profile", "email") if res.ok?
          connection.tenant = tokens["team_id"]
        else
          res = Disk::Importer.transport.call(:post, "#{at(:api)}/users/get_current_account", headers: headers, body: "null")
          connection.account_email = res.json["email"] if res.ok?
          connection.tenant = tokens["team_id"].presence || tokens["account_id"]
        end
      end

      def fetch_token = refreshed_token

      # Every active member's home folder and every team folder.
      def spaces
        members = paged("team/members/list_v2", "team/members/list/continue_v2", "members", { limit: 200 })
          .select { |m| m.dig("profile", "status", ".tag") == "active" }.map do |m|
            p = m["profile"]
            Space.new(id: "member:#{p['team_member_id']}", kind: Disk::Import::SPACE_MEMBER,
                      name: p.dig("name", "display_name") || p["email"], email: p["email"])
          end
        folders = paged("team/namespaces/list", "team/namespaces/list/continue", "namespaces", { limit: 1000 })
          .select { |n| n.dig("namespace_type", ".tag") == "team_folder" }.uniq { |n| n["namespace_id"] }.map do |n|
            Space.new(id: "shared:#{n['namespace_id']}", kind: Disk::Import::SPACE_SHARED, name: n["name"])
          end
        members + folders
      end

      # The team folder's own namespace; its members become the share's.
      def root_id = namespace && "ns:#{namespace}"

      def each_item(cursor)
        @paths = {}
        body = cursor.present? ? continue(cursor) : list_start
        page_cursor = cursor.presence
        loop do
          body.fetch("entries", []).each { |e| yield item_for(e, page_cursor) }
          page_cursor = body["cursor"]
          return page_cursor unless body["has_more"]

          body = continue(page_cursor)
        end
      end

      def folder(id)
        res = rpc("files/get_metadata", { path: id })
        res.ok? ? item_for(res.json, nil) : nil
      end

      def download(item) = content("files/download", { path: item.id })

      def export(item, format)
        file = content("files/export", { path: item.id, export_format: format })
        meta = JSON.parse(@last_result.to_s)
        @exported_sizes = { item.id => meta.dig("export_metadata", "size") }
        file
      rescue JSON::ParserError
        file
      end

      def verify(item, file)
        if item.kind == :file
          return file.size == item.size.to_i if item.hash.blank?

          return ContentHash.file(file.path) == item.hash
        end
        expected = @exported_sizes.to_h[item.id]
        (expected.nil? || file.size == expected) && export_complete?(file, item.ext)
      end

      def permissions(item)
        folder_id = item.id == root_id ? namespace : item.format
        res = if item.kind == :folder then rpc("sharing/list_folder_members", { shared_folder_id: folder_id, limit: 1000 })
        else rpc("sharing/list_file_members", { file: item.id, limit: 300 })
        end
        return [] unless res.ok?

        role = ->(m) { m.dig("access_type", ".tag") }
        res.json.fetch("users", []).map { |u| Perm.new(type: :user, email: u.dig("user", "email"), role: role.(u)) } +
          res.json.fetch("invitees", []).filter_map do |i|
            email = i.dig("invitee", "email")
            Perm.new(type: :user, email: email, role: role.(i)) if email
          end +
          res.json.fetch("groups", []).map { |g| Perm.new(type: :group, name: g.dig("group", "group_name"), role: role.(g)) }
      end

      private

      def namespace
        import.space_id.to_s.delete_prefix("shared:") if import.space_kind == Disk::Import::SPACE_SHARED && import.space_id
      end

      def list_start
        arg = { path: "", recursive: true, include_has_explicit_shared_members: true, limit: 2000 }
        # A member's home without the team folders mounted in it: those are imported as shares.
        arg[:include_mounted_folders] = false if import.space_kind == Disk::Import::SPACE_MEMBER
        call_json("files/list_folder", arg)
      end

      # A reset cursor means list everything again; re-runs are idempotent.
      def continue(cursor)
        res = rpc("files/list_folder/continue", { cursor: cursor })
        return list_start if res.status == 409 && res.body.to_s.include?("reset")

        check!(res)
        res.json
      end

      def item_for(e, cursor)
        path = e["path_lower"]
        tag = e[".tag"]
        return Item.new(deleted: true, path: path, cursor: cursor) if tag == "deleted"

        attrs = { id: e["id"], name: e["name"], parent_id: parent_id_for(File.dirname(path.to_s)), cursor: cursor, path: path }
        if tag == "folder"
          @paths[path] = e["id"]
          shared_id = e.dig("sharing_info", "shared_folder_id") || e["shared_folder_id"]
          # format carries the shared folder id permissions are read from.
          return Item.new(kind: :folder, shared: shared_id.present?, format: shared_id, **attrs)
        end

        attrs.merge!(modified_at: e["server_modified"] && Time.zone.parse(e["server_modified"]), size: e["size"],
                     hash: e["content_hash"], shared: e["has_explicit_shared_members"] == true)
        return Item.new(kind: :file, **attrs) unless e["is_downloadable"] == false

        info = e["export_info"] || {}
        options = [info["export_as"], *info["export_options"]].compact
        base = File.basename(e["name"].to_s, ".*")
        return Item.new(kind: :page, format: "markdown", ext: "md", **attrs, name: base) if options.include?("markdown")
        return Item.new(kind: :export, format: options.first, ext: options.first, **attrs, name: base) if options.any?

        Item.new(kind: :file, **attrs, skip: "Dropbox offers neither a download nor an export for this file")
      end

      # Dropbox lists by path; Disk files hang off ids. The parent's id comes
      # from the folders seen in this run, else one metadata call.
      def parent_id_for(dir)
        return nil if dir.blank? || dir == "/" || dir == "."
        return @paths[dir] if @paths.key?(dir)

        res = rpc("files/get_metadata", { path: dir })
        @paths[dir] = res.ok? ? res.json["id"] : nil
      end

      def paged(first, more, key, arg)
        body = call_json(first, arg)
        out = body.fetch(key, [])
        while body["has_more"]
          body = call_json(more, { cursor: body["cursor"] })
          out.concat(body.fetch(key, []))
        end
        out
      end

      def call_json(path, arg)
        res = rpc(path, arg)
        check!(res)
        res.json
      end

      def rpc(path, arg)
        res = request(:post, "#{at(:api)}/#{path}", headers: scoped_headers.merge("Content-Type" => "application/json"),
                                               body: arg.to_json)
        stop_on_cap!(res)
        res
      end

      def content(path, arg)
        file = tempfile
        res = request(:post, "#{at(:content)}/#{path}", io: file, headers: scoped_headers.merge("Dropbox-API-Arg" => header_json(arg)))
        stop_on_cap!(res)
        raise ItemFailed, "#{label} answered #{res.status}: #{res.body.to_s.truncate(200)}" unless res.ok?

        @last_result = res.header("dropbox-api-result")
        file.rewind
        file
      rescue StandardError
        file&.close!
        raise
      end

      def check!(res)
        raise ItemFailed, "#{label} answered #{res.status}: #{res.body.to_s.truncate(200)}" unless res.ok?
      end

      # The team's monthly data transport cap: terminal for the month, reported, not retried.
      def stop_on_cap!(res)
        return unless res.status == 403 && res.body.to_s.include?("invalid_account_type")

        message = begin
          res.json.dig("user_message", "text")
        rescue JSON::ParserError
          nil
        end
        raise Stop.new(Disk::Import::PAUSE_TRANSFER_CAP,
                       message || "This Dropbox team has used its data transport API calls for the month")
      end

      # Who the call acts as, and in which namespace.
      def scoped_headers
        case import.space_kind
        when Disk::Import::SPACE_MEMBER
          { "Dropbox-API-Select-User" => import.space_id.to_s.delete_prefix("member:") }
        when Disk::Import::SPACE_SHARED
          return {} unless import.space_id # listing spaces: team endpoints

          { "Dropbox-API-Select-Admin" => admin_member_id,
            "Dropbox-API-Path-Root" => { ".tag" => "namespace_id", "namespace_id" => namespace }.to_json }
        else {}
        end
      end

      def admin_member_id
        @admin_member_id ||= begin
          res = request(:post, "#{at(:api)}/team/token/get_authenticated_admin", headers: { "Content-Type" => "application/json" },
                                                                             body: "null")
          check!(res)
          res.json.dig("admin_profile", "team_member_id")
        end
      end

      # Dropbox-API-Arg is an HTTP header: non-ASCII must be escaped.
      def header_json(arg) = arg.to_json.gsub(/[^\x00-\x7f]/) { |c| format("\\u%04x", c.ord) }

      # Dropbox's content_hash (docs.dropboxapi.com, content hash): SHA-256 of
      # each 4 MiB block, concatenated, then SHA-256 of that, in hex.
      class ContentHash
        BLOCK = 4 * 1024 * 1024

        def self.file(path)
          File.open(path, "rb") { |f| of_io(f) }
        end

        def self.of_io(io)
          digests = +"".b
          while (block = io.read(BLOCK))
            digests << Digest::SHA256.digest(block)
          end
          Digest::SHA256.hexdigest(digests)
        end
      end
    end
  end
end
