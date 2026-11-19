module Disk
  class Importer
    # Microsoft 365 through Microsoft Graph. A member's OneDrive into C:\
    # (delegated Files.Read); with a tenant admin's consent to the application
    # permissions, every user's OneDrive into their C:\ and each SharePoint
    # document library into a share. Enumerates with delta per drive and keeps
    # the delta link as the cursor; a 410 restarts the drive from the Location
    # Graph gives. Files download through the short-lived pre-authenticated
    # URL, fetched just before use, and verify against quickXorHash. OneNote
    # notebooks (package facet) and SharePoint lists have no file and are reported.
    class Microsoft < Importer
      GRAPH = "https://graph.microsoft.com/v1.0".freeze
      LOGIN = "https://login.microsoftonline.com".freeze
      SELECT = "id,name,folder,file,package,deleted,parentReference,lastModifiedDateTime,size,shared,remoteItem,root".freeze
      ROLE_ORDER = %w[read write owner].freeze

      def self.identify(connection, tokens)
        connection.account_email = OauthProvider.fetch_email(OauthProvider::MICROSOFT, tokens["access_token"], url: "#{at(:graph)}/me")
        connection.tenant = token_claims(tokens["access_token"])["tid"] || connection.account_email&.split("@")&.last
      end

      # The access token's claims, unverified: only to learn the tenant id
      # that groups connections under one throttling budget.
      def self.token_claims(token)
        JSON.parse(Base64.urlsafe_decode64(token.to_s.split(".")[1].to_s.then { |p| p + ("=" * (-p.size % 4)) }))
      rescue ArgumentError, JSON::ParserError
        {}
      end

      def fetch_token
        return refreshed_token unless connection.org?

        form = { client_id: client[:id], client_secret: client[:secret], grant_type: "client_credentials",
                 scope: "https://graph.microsoft.com/.default" }
        res = request(:post, "#{at(:login)}/#{connection.tenant}/oauth2/v2.0/token", auth: false,
                      headers: { "Content-Type" => "application/x-www-form-urlencoded" }, body: URI.encode_www_form(form))
        unless res.ok?
          raise Stop.new(Disk::Import::PAUSE_AUTHORIZATION, "Microsoft refused the app's access to this tenant " \
                                                            "(#{res.status}). A tenant admin must consent again.")
        end
        [res.json["access_token"], res.json["expires_in"]]
      end

      # Every user's OneDrive and every SharePoint document library.
      def spaces
        users = paged("#{at(:graph)}/users?$select=id,displayName,mail,userPrincipalName&$top=999").map do |u|
          Space.new(id: "member:#{u['id']}", kind: Disk::Import::SPACE_MEMBER, name: u["displayName"],
                    email: u["mail"].presence || u["userPrincipalName"])
        end
        libraries = paged("#{at(:graph)}/sites/getAllSites?$select=id,displayName&$top=999").flat_map do |site|
          paged("#{at(:graph)}/sites/#{site['id']}/drives?$select=id,name,driveType").map do |d|
            name = d["name"] == "Documents" ? site["displayName"] : "#{site['displayName']} - #{d['name']}"
            Space.new(id: "shared:#{d['id']}", kind: Disk::Import::SPACE_SHARED, name: name)
          end
        end
        users + libraries
      end

      def root_id = @root_id ||= get_json("#{drive}/root?$select=id")["id"]

      def each_item(cursor, &)
        url = cursor.presence || begin
          lists(&) if import.space_kind == Disk::Import::SPACE_SHARED
          "#{drive}/root/delta?$select=#{SELECT}"
        end
        loop do
          res = request(:get, graph_link!(url))
          if res.status == 410 # the token is no good: enumerate the drive again from where Graph says
            url = res.header("location").presence || "#{drive}/root/delta?$select=#{SELECT}"
            next
          end
          raise ItemFailed, "#{label} answered #{res.status}: #{error_of(res)}" unless res.ok?

          # An item may appear more than once in a run; processing each in
          # order leaves the last one standing.
          res.json.fetch("value", []).each { |i| yield item_for(i, url) }
          return graph_link!(res.json["@odata.deltaLink"]) if res.json["@odata.deltaLink"]

          url = res.json.fetch("@odata.nextLink")
        end
      end

      def folder(id)
        res = request(:get, "#{drive}/items/#{id}?$select=#{SELECT}")
        res.ok? && !res.json["deleted"] ? item_for(res.json, nil) : nil
      end

      # The pre-authenticated URL expires within minutes: ask for it now, and
      # send nothing of ours to it.
      def download(item)
        url = get_json("#{drive}/items/#{item.id}")["@microsoft.graph.downloadUrl"] ||
              raise(ItemFailed, "#{label} gave no download address for this file")
        pin = destination!(url)
        file = tempfile
        res = request(:get, url, io: file, auth: false, pin: pin)
        raise ItemFailed, "The download answered #{res.status}" unless res.ok?

        file.rewind
        file
      rescue StandardError
        file&.close!
        raise
      end

      def export(_item, _format) = raise(ItemFailed, "Microsoft files are downloaded, not exported")

      def verify(item, file)
        return file.size == item.size.to_i if item.hash.blank?

        QuickXor.file(file.path) == item.hash
      end

      def permissions(item)
        path = item.id == root_id ? "#{drive}/root/permissions" : "#{drive}/items/#{item.id}/permissions"
        res = request(:get, path)
        return [] unless res.ok?

        res.json.fetch("value", []).filter_map do |p|
          role = Array(p["roles"]).max_by { |r| ROLE_ORDER.index(r) || -1 }
          next Perm.new(type: :link, role: role, name: p.dig("link", "scope")) if p["link"]

          g = p["grantedToV2"] || {}
          if (group = g["group"] || g["siteGroup"])
            next Perm.new(type: :group, name: group["displayName"] || group["loginName"], role: role)
          end

          email = g.dig("user", "email") || g.dig("siteUser", "email") || p.dig("invitation", "email")
          name = g.dig("user", "displayName") || g.dig("siteUser", "displayName")
          Perm.new(type: :user, email: email || name, role: role) if email || name
        end
      end

      private

      def client = Disk::ImportSource.client(import.provider)

      # The Graph address of the drive this import reads.
      def drive
        case import.space_kind
        when Disk::Import::SPACE_SHARED then "#{at(:graph)}/drives/#{import.space_id.to_s.delete_prefix('shared:')}"
        when Disk::Import::SPACE_MEMBER then "#{at(:graph)}/users/#{import.space_id.to_s.delete_prefix('member:')}/drive"
        else "#{at(:graph)}/me/drive"
        end
      end

      # A library's site may hold lists and other non-file content: each one
      # is reported, once per full listing.
      def lists
        site = get_json("#{drive}?$select=id,sharePointIds").dig("sharePointIds", "siteId")
        return unless site

        paged("#{at(:graph)}/sites/#{site}/lists?$select=id,displayName,list").each do |l|
          next if l.dig("list", "template") == "documentLibrary"

          yield Item.new(id: "list:#{l['id']}", name: l["displayName"], kind: :file, parent_id: nil,
                         skip: "A SharePoint #{l.dig('list', 'template') == 'genericList' ? 'list' : 'list or page library'} has no files")
        end
      end

      def item_for(i, cursor)
        attrs = { id: i["id"], name: i["name"], parent_id: i.dig("parentReference", "id"), cursor: cursor,
                  modified_at: i["lastModifiedDateTime"] && Time.zone.parse(i["lastModifiedDateTime"]),
                  size: i["size"], shared: i["shared"].present? }
        return Item.new(id: i["id"], deleted: true, cursor: cursor) if i["deleted"]
        return Item.new(kind: :folder, **attrs) if i["folder"] || i["root"]
        if (pkg = i["package"])
          what = pkg["type"] == "oneNote" ? "A OneNote notebook" : "A #{pkg['type']} package"
          return Item.new(kind: :file, **attrs, skip: "#{what} has no file to download. Open it in Microsoft 365 to export it.")
        end
        return Item.new(kind: :file, **attrs, skip: "Shared with you from someone else's drive") if i["remoteItem"]

        Item.new(kind: :file, hash: i.dig("file", "hashes", "quickXorHash"), **attrs)
      end

      # A continuation Graph hands back (nextLink, deltaLink, a 410's
      # Location, a stored cursor) is followed with the bearer token, so it
      # must stay on the Graph this server is configured for: same scheme,
      # host and port, under its version path. Checked before following or storing.
      def graph_link!(url)
        base = URI(at(:graph))
        uri = URI(url.to_s)
        same = [uri.scheme, uri.host, uri.port] == [base.scheme, base.host, base.port] && uri.userinfo.nil? &&
               uri.path.start_with?("#{base.path}/")
        same ? url : raise(ItemFailed, "#{label} returned a continuation link outside Microsoft Graph; stopped")
      rescue URI::InvalidURIError
        raise ItemFailed, "#{label} returned a continuation link that is not a URL; stopped"
      end

      def get_json(url)
        res = request(:get, url)
        raise ItemFailed, "#{label} answered #{res.status}: #{error_of(res)}" unless res.ok?

        res.json
      end

      def paged(url)
        out = []
        while url
          body = get_json(graph_link!(url))
          out.concat(body.fetch("value", []))
          url = body["@odata.nextLink"]
        end
        out
      end

      def error_of(res)
        err = res.json["error"]
        err.is_a?(Hash) ? "#{err['code']} #{err['message']}".strip : err.to_s
      rescue JSON::ParserError
        res.body.to_s.truncate(200)
      end

      # Microsoft's quickXorHash (learn.microsoft.com/onedrive/developer/code-snippets/quickxorhash):
      # byte i is XORed into a 160-bit block shifted left by 11 * i bits,
      # circularly, and the length is XORed into the top 64 bits. Bytes 160
      # apart land on the same shift, so the stream is folded into one 160-byte
      # row with big-integer XORs (fast in Ruby) and the shifts applied once.
      class QuickXor
        ROW = 160 # bytes; also the block width in bits
        MASK = (1 << ROW) - 1
        READ = 1.megabyte

        def self.file(path)
          q = new
          File.open(path, "rb") { |f| while (chunk = f.read(READ)) do q << chunk end }
          q.base64
        end

        def initialize
          @lanes = 0
          @carry = "".b
          @length = 0
        end

        def <<(data)
          @length += data.bytesize
          buf = @carry + data.b
          rows = buf.bytesize / ROW
          @carry = buf.byteslice(rows * ROW..)
          @lanes ^= fold(buf.byteslice(0, rows * ROW), rows) if rows.positive?
          self
        end

        def base64
          lanes = @lanes ^ fold(@carry + ("\0" * (ROW - @carry.bytesize)).b, 1)
          block = 0
          ROW.times do |j|
            byte = (lanes >> (8 * (ROW - 1 - j))) & 0xff
            next if byte.zero?

            shift = (j * 11) % ROW
            v = byte << shift
            block ^= (v | (v >> ROW)) & MASK
          end
          block ^= @length << (ROW - 64)
          Base64.strict_encode64([block.to_s(16).rjust(40, "0")].pack("H*").reverse)
        end

        private

        # XOR of `rows` 160-byte rows, as one 1280-bit integer (row byte 0 most significant).
        def fold(bytes, rows)
          n = bytes.unpack1("H*").to_i(16)
          span = 1
          span <<= 1 while span < rows
          while span > 1
            span >>= 1
            bits = span * ROW * 8
            n = (n >> bits) ^ (n & ((1 << bits) - 1))
          end
          n
        end
      end
    end
  end
end
