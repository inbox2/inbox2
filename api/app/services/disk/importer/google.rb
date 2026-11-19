module Disk
  class Importer
    # Google Drive (Drive API v3). My Drive into C:\, shared drives into
    # shares, members' My Drives through domain-wide delegation when a service
    # account is configured. Native Docs become pages (markdown export),
    # Sheets and Slides .xlsx and .pptx, Drawings .pdf; other Google types and
    # shortcuts are reported. Files verify against md5Checksum.
    #
    # Cursor: {"start" => token, "page" => pageToken} during the first full
    # listing; {"changes" => token} after it, so a re-run reads only changes.
    class Google < Importer
      API = "https://www.googleapis.com/drive/v3".freeze
      DIRECTORY = "https://admin.googleapis.com/admin/directory/v1/users".freeze
      TOKEN = OauthProvider.token_url(OauthProvider::GOOGLE)
      USERINFO = OauthProvider.config(OauthProvider::GOOGLE)[:userinfo_url]
      FIELDS = "id,name,mimeType,parents,modifiedTime,size,md5Checksum,shared,trashed".freeze
      FOLDER = "application/vnd.google-apps.folder".freeze
      SHORTCUT = "application/vnd.google-apps.shortcut".freeze
      # Google type => [kind, export MIME type, extension]
      EXPORTS = {
        "application/vnd.google-apps.document" => [:page, "text/markdown", "md"],
        "application/vnd.google-apps.spreadsheet" => [:export, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", "xlsx"],
        "application/vnd.google-apps.presentation" => [:export, "application/vnd.openxmlformats-officedocument.presentationml.presentation", "pptx"],
        "application/vnd.google-apps.drawing" => [:export, "application/pdf", "pdf"]
      }.freeze

      def self.identify(connection, tokens)
        email = OauthProvider.fetch_email(OauthProvider::GOOGLE, tokens["access_token"], url: at(:userinfo))
        connection.account_email = email
        connection.tenant = email&.split("@")&.last
      end

      def fetch_token = refreshed_token

      # Shared drives the connected admin can read, and with domain-wide
      # delegation configured, every active user's My Drive.
      def spaces
        drives = paged("#{at(:api)}/drives?pageSize=100", "drives").map do |d|
          Space.new(id: "shared:#{d['id']}", kind: Disk::Import::SPACE_SHARED, name: d["name"])
        end
        return drives unless Disk::ImportSource.google_service_account

        @directory_token = delegated(connection.account_email, "https://www.googleapis.com/auth/admin.directory.user.readonly")[0]
        users = paged("#{at(:directory)}?customer=my_customer&maxResults=500", "users")
        @directory_token = nil
        drives + users.reject { |u| u["suspended"] }.map do |u|
          Space.new(id: "member:#{u['id']}", kind: Disk::Import::SPACE_MEMBER, name: u.dig("name", "fullName") || u["primaryEmail"],
                    email: u["primaryEmail"])
        end
      end

      def root_id
        @root_id ||= shared_drive_id || get_json("#{at(:api)}/files/root?fields=id")["id"]
      end

      def each_item(cursor, &)
        state = cursor.present? ? JSON.parse(cursor) : {}
        return changes(state["changes"], &) if state["changes"]

        start = state["start"] || get_json("#{at(:api)}/changes/startPageToken?#{drive_params}")["startPageToken"]
        page = state["page"]
        loop do
          body = get_json("#{at(:api)}/files?#{list_params(page)}")
          body.fetch("files", []).each { |f| yield item_for(f, { "start" => start, "page" => page }.compact.to_json) }
          page = body["nextPageToken"]
          break unless page
        end
        { "changes" => start }.to_json
      end

      def folder(id)
        res = request(:get, "#{at(:api)}/files/#{id}?fields=#{FIELDS}&supportsAllDrives=true")
        return nil if res.status == 404 || !res.ok? || res.json["trashed"]

        item_for(res.json, nil)
      end

      def download(item) = fetch("#{at(:api)}/files/#{item.id}?alt=media&supportsAllDrives=true")

      def export(item, format)
        fetch("#{at(:api)}/files/#{item.id}/export?#{{ mimeType: format }.to_query}")
      rescue ItemFailed => e
        raise ItemFailed, "Over Google's 10 MB export limit, so Google would not convert it" if e.message.include?("exportSizeLimitExceeded")

        raise
      end

      def verify(item, file)
        return export_complete?(file, item.ext) unless item.kind == :file
        return file.size == item.size.to_i if item.hash.blank?

        Digest::MD5.file(file.path).hexdigest == item.hash
      end

      def permissions(item)
        res = request(:get, "#{at(:api)}/files/#{item.id}/permissions?supportsAllDrives=true&" \
                            "fields=permissions(type,role,emailAddress,domain,displayName)")
        return [] unless res.ok?

        res.json.fetch("permissions", []).map do |p|
          case p["type"]
          when "user" then Perm.new(type: :user, email: p["emailAddress"], role: p["role"])
          when "group" then Perm.new(type: :group, email: p["emailAddress"], name: p["emailAddress"] || p["displayName"], role: p["role"])
          else Perm.new(type: :link, role: p["role"], name: p["domain"])
          end
        end
      end

      # A member's My Drive is read as that member, through the service account.
      def token
        return @directory_token if @directory_token
        return super unless import.space_kind == Disk::Import::SPACE_MEMBER

        @delegated = nil if @delegated && @delegated[1] < 1.minute.from_now
        @delegated ||= delegated(import.source_email, "https://www.googleapis.com/auth/drive.readonly")
        @delegated[0]
      end

      def forget_token!
        @delegated = nil
        super
      end

      private

      def shared_drive_id
        import.space_id.to_s.delete_prefix("shared:") if import.space_kind == Disk::Import::SPACE_SHARED
      end

      def drive_params
        id = shared_drive_id
        id ? "driveId=#{id}&supportsAllDrives=true" : ""
      end

      def list_params(page)
        query = { q: "trashed = false", pageSize: 1000, fields: "nextPageToken,files(#{FIELDS})", pageToken: page }
        query.merge!(corpora: "drive", driveId: shared_drive_id, includeItemsFromAllDrives: true, supportsAllDrives: true) if shared_drive_id
        query.compact.to_query
      end

      def changes(token)
        loop do
          query = { pageToken: token, pageSize: 1000, includeRemoved: true,
                    fields: "nextPageToken,newStartPageToken,changes(fileId,removed,file(#{FIELDS}))" }
          query.merge!(shared_drive_id ? { driveId: shared_drive_id, includeItemsFromAllDrives: true, supportsAllDrives: true } :
                                         { restrictToMyDrive: true })
          body = get_json("#{at(:api)}/changes?#{query.to_query}")
          body.fetch("changes", []).each do |c|
            checkpoint = { "changes" => token }.to_json
            file = c["file"]
            yield(if c["removed"] || file.nil? || file["trashed"]
                    Item.new(id: c["fileId"], deleted: true, cursor: checkpoint)
                  else
                    item_for(file, checkpoint)
                  end)
          end
          return { "changes" => body["newStartPageToken"] }.to_json if body["newStartPageToken"]

          token = body["nextPageToken"]
        end
      end

      def item_for(f, cursor)
        mime = f["mimeType"]
        attrs = { id: f["id"], name: f["name"], parent_id: f["parents"]&.first, cursor: cursor,
                  modified_at: f["modifiedTime"] && Time.zone.parse(f["modifiedTime"]), shared: f["shared"] == true,
                  size: f["size"]&.to_i, hash: f["md5Checksum"] }
        # No parent: shared with the person, not placed in their My Drive.
        attrs[:skip] = "Shared with you but not in your My Drive" if attrs[:parent_id].nil?
        if mime == FOLDER then Item.new(kind: :folder, **attrs)
        elsif (kind, format, ext = EXPORTS[mime]) && kind
          Item.new(kind: kind, format: format, ext: ext, **attrs)
        elsif mime == SHORTCUT
          Item.new(kind: :file, **attrs, skip: "A shortcut. Disk imports the original from its own folder.")
        elsif mime.to_s.start_with?("application/vnd.google-apps.")
          type = mime.delete_prefix("application/vnd.google-apps.")
          Item.new(kind: :file, **attrs, skip: "A Google #{type.humanize.downcase} has no file to export")
        else Item.new(kind: :file, **attrs)
        end
      end

      def get_json(url)
        res = request(:get, url)
        raise ItemFailed, "#{label} answered #{res.status}: #{error_of(res)}" unless res.ok?

        res.json
      end

      def paged(url, key)
        out = []
        page = nil
        loop do
          body = get_json(page ? "#{url}&pageToken=#{CGI.escape(page)}" : url)
          out.concat(body.fetch(key, []))
          page = body["nextPageToken"]
          return out unless page
        end
      end

      def fetch(url)
        file = tempfile
        res = request(:get, url, io: file)
        raise ItemFailed, "#{label} answered #{res.status}: #{error_of(res)}" unless res.ok?

        file.rewind
        file
      rescue StandardError
        file&.close!
        raise
      end

      def error_of(res)
        err = res.json["error"]
        reason = err.is_a?(Hash) ? Array(err["errors"]).first&.dig("reason") : nil
        [err.is_a?(Hash) ? err["message"] : err, reason].compact.join(" ")
      rescue JSON::ParserError
        res.body.to_s.truncate(200)
      end

      # [access_token, expires_at] for `subject`, signed with the service
      # account's key (OAuth 2.0 JWT bearer grant, RS256).
      def delegated(subject, scope)
        sa = Disk::ImportSource.google_service_account ||
             raise(Stop.new(Disk::Import::PAUSE_AUTHORIZATION, "Domain-wide access is not configured on this server"))
        now = Time.current.to_i
        claims = { iss: sa["client_email"], scope: scope, aud: at(:token), sub: subject, iat: now, exp: now + 3600 }
        assertion = jwt(claims, OpenSSL::PKey::RSA.new(sa["private_key"]))
        res = request(:post, at(:token), auth: false, headers: { "Content-Type" => "application/x-www-form-urlencoded" },
                                        body: URI.encode_www_form(grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
                                                                  assertion: assertion))
        unless res.ok?
          raise Stop.new(Disk::Import::PAUSE_AUTHORIZATION,
                         "Google refused domain-wide access for #{subject}: #{error_of(res)}. " \
                         "Check the service account's delegation in the Google Workspace admin console.")
        end
        [res.json["access_token"], res.json.fetch("expires_in", 3600).to_i.seconds.from_now]
      end

      def jwt(claims, key)
        encode = ->(h) { Base64.urlsafe_encode64(h.to_json, padding: false) }
        input = "#{encode.({ alg: 'RS256', typ: 'JWT' })}.#{encode.(claims)}"
        "#{input}.#{Base64.urlsafe_encode64(key.sign(OpenSSL::Digest.new('SHA256'), input), padding: false)}"
      end
    end
  end
end
