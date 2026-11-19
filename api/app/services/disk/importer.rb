module Disk
  # The importer base (docs/plans/disk-build.md sections 3 and 9b, spec F10).
  # One instance runs one Disk::Import. An adapter (Importer::Google,
  # ::Microsoft, ::Dropbox) implements:
  #
  #   each_item(cursor) { |item| }  every Item in the space from cursor; returns
  #                                 the cursor the next run starts from. Each
  #                                 item's .cursor is a safe checkpoint.
  #   download(item)                a Tempfile with the source bytes
  #   export(item, format)          a Tempfile with the converted bytes
  #   permissions(item)             [Perm] for an item marked shared
  #   verify(item, file)            true when the bytes match the source hash,
  #                                 or for a converted item, a complete export
  #   folder(source_id)             the Item for a parent folder not yet seen,
  #                                 or nil when it is outside the space
  #   fetch_token                   [access_token, expires_in] for the connection
  #
  # The base owns checkpoints, quota pauses, throttling waits, idempotent
  # re-runs through disk_import_items, sharing and the report. Files are
  # written through Disk::UploadOps (reservation, quota, storage, events),
  # folders through Disk::NodeOps, pages through NodeOps#save_page.
  class Importer
    # kind: :folder, :file (bytes with a source hash), :export (converted to
    # an ordinary file, `format` and `ext`), :page (exported as markdown).
    # skip: a reason when the item has no content Disk can hold (reported).
    # path: the source's path, kept for sources that report a deletion by
    # path alone (Dropbox); a deleted item then comes with path and no id.
    Item = Struct.new(:id, :name, :kind, :parent_id, :modified_at, :size, :hash, :format, :ext,
                      :deleted, :skip, :shared, :cursor, :path, keyword_init: true)
    # type: :user, :group, :link (anyone or a domain); role is the source's word.
    Perm = Struct.new(:type, :email, :name, :role, :members, keyword_init: true)
    # kind: Disk::Import::SPACE_*; email names the person for a member space,
    # member the org member it matched (set by the controller).
    Space = Struct.new(:id, :kind, :name, :email, :member, keyword_init: true)

    # A throttle response: hold the tenant for `wait` seconds.
    class Throttled < StandardError
      attr_reader :wait

      def initialize(wait)
        @wait = wait.to_i.clamp(1, 3600)
        super("The source asked us to wait #{@wait} seconds")
      end
    end

    # Stops the import with a reason a person can act on (revoked
    # authorisation, a data transport cap); resumable.
    class Stop < StandardError
      attr_reader :reason

      def initialize(reason, message)
        @reason = reason
        super(message)
      end
    end

    ItemFailed = Class.new(StandardError) # this item only: reported, the run goes on

    # Source roles to Disk roles (9b). Grants stop at edit; share memberships take manage.
    ROLES = {
      "owner" => Disk::ROLE_MANAGE, "organizer" => Disk::ROLE_MANAGE,
      "fileorganizer" => Disk::ROLE_EDIT, "writer" => Disk::ROLE_EDIT, "editor" => Disk::ROLE_EDIT,
      "write" => Disk::ROLE_EDIT,
      "reader" => Disk::ROLE_VIEW, "commenter" => Disk::ROLE_VIEW, "viewer" => Disk::ROLE_VIEW,
      "viewer_no_comment" => Disk::ROLE_VIEW, "read" => Disk::ROLE_VIEW
    }.freeze

    THROTTLE_DEFAULT = 60 # seconds, when a throttle response names no Retry-After
    REPORT_PEOPLE_MAX = 500 # distinct unmatched people and groups kept in the report

    class << self
      attr_writer :transport

      def transport = @transport ||= Http.new

      def for(import)
        klass = Disk::ImportSource.adapter(import.provider) ||
                raise(Disk::Refused.new("The #{import.provider} importer is not available", status: 503))
        klass.new(import)
      end
    end

    attr_reader :import, :connection

    def initialize(import)
      @import = import
      @connection = import.connection
    end

    # A provider endpoint: the adapter's constant (API, GRAPH, ...) or its
    # test override (Disk::ImportSource.url).
    def self.at(name) = Disk::ImportSource.url(self.name.demodulize.downcase, name, const_get(name.to_s.upcase))
    def at(name) = self.class.at(name)

    # Called once a grant is made: fills account_email and tenant from the
    # token response or the source (the callback saves the connection).
    def self.identify(connection, tokens); end

    # The spaces a connection can import from (GET /imports/sources).
    def spaces = raise(NotImplementedError)

    # Runs the import from its checkpoint until it is done, paused, cancelled
    # or held by a throttle (then the job is scheduled for when the hold ends).
    def run
      @counts = import.counts.to_h
      @report = import.report.to_h
      @members = Disk::ImportSource.member_index(import.organization)
      share_space! if import.space_kind == Disk::Import::SPACE_SHARED
      final = each_item(import.cursor) do |item|
        raise Cancelled if Disk::Import.where(id: import.id).pick(:state) == Disk::Import::STATE_CANCELLED

        process(item)
        checkpoint!(item.cursor)
      end
      import.update!(state: Disk::Import::STATE_DONE, cursor: final, counts: @counts, report: @report,
                     finished_at: Time.current, pause_reason: nil, error: nil)
    rescue Cancelled
      import.update_columns(counts: @counts, report: @report, updated_at: Time.current)
    rescue Throttled => e
      checkpoint!(nil)
      import.update!(state: Disk::Import::STATE_QUEUED)
      Disk::ImportJob.set(wait: e.wait.seconds).perform_later(import.id)
    rescue Stop => e
      pause!(e.reason, e.message)
    rescue Disk::Refused => e
      raise unless e.extra[:code] == Disk::Quota::FULL

      pause!(Disk::Import::PAUSE_QUOTA, "#{e.message}. Free some space, then resume the import.")
    end

    Cancelled = Class.new(StandardError)

    # One source item, idempotently. Public for the adapters' parent lookups.
    def process(item)
      return target if item.id && item.id == root_id

      bump(:seen)
      return deleted_at_source(item) if item.deleted

      row = Disk::ImportItem.find_or_initialize_by(organization_id: import.organization_id, provider: import.provider,
                                                   target_node_id: import.target_node_id, source_id: item.id)
      row.detail = row.detail.except("moved", "public_link") # this run's flags only
      return finish(row, item, Disk::ImportItem::STATUS_SKIPPED, reason: item.skip) if item.skip

      parent = parent_node(item.parent_id)
      return finish(row, item, Disk::ImportItem::STATUS_SKIPPED, reason: "Not in this drive") unless parent

      node = item.kind == :folder ? import_folder(row, item, parent) : import_content(row, item, parent)
      share!(row, item, node) if node && item.shared
      node
    rescue ItemFailed, Http::Incomplete => e
      finish(row, item, Disk::ImportItem::STATUS_FAILED, reason: e.message)
      nil
    rescue Disk::Refused => e
      raise if e.extra[:code] == Disk::Quota::FULL

      finish(row, item, Disk::ImportItem::STATUS_FAILED, reason: e.message)
      nil
    end

    # The target node for a source parent id, importing the parent folder first
    # when it has not been seen. nil when the item is outside the space.
    def parent_node(source_parent_id)
      return target if source_parent_id.nil? || source_parent_id == root_id

      @folders ||= {}
      return @folders[source_parent_id] if @folders.key?(source_parent_id)

      row = item_row(source_parent_id)
      node = row&.live_node
      node ||= (folder_item = folder(source_parent_id)) && process(folder_item)
      @folders[source_parent_id] = node
    end

    # The source id of the space's top folder; items under it land in target.
    def root_id = nil

    # Authenticated request to the source. Holds the whole tenant on a
    # throttle response and refreshes the token once on a 401.
    def request(method, url, headers: {}, body: nil, io: nil, auth: true, pin: nil)
      if (until_at = connection&.waiting_until)
        raise Throttled, (until_at - Time.current).ceil
      end

      retried = false
      begin
        heads = auth ? headers.merge("Authorization" => "Bearer #{token}") : headers
        io&.rewind
        io&.truncate(0)
        response = Disk::Importer.transport.call(method, url, headers: heads, body: body, io: io, pin: pin)
        if throttled?(response)
          wait = response.header("retry-after").to_i
          wait = THROTTLE_DEFAULT unless wait.positive?
          connection&.throttle!(wait)
          raise Throttled, wait
        end
        if response.status == 401 && auth && !retried
          retried = true
          forget_token!
          raise RetryAuth
        end
        if response.status == 401
          raise Stop.new(Disk::Import::PAUSE_AUTHORIZATION, "#{label} no longer accepts this connection. " \
                                                            "Connect again, then resume.")
        end
        response
      rescue RetryAuth
        retry
      end
    end

    RetryAuth = Class.new(StandardError)

    # A URL a provider response supplied (a download address) is fetched only
    # over https to a host whose every address is public, and answers the IP
    # to pin the connection to. Outside production an origin this provider's
    # endpoint overrides name also passes (nil: no pin), so the e2e fakes on
    # 127.0.0.1 keep working. Anything else fails the item.
    def destination!(url)
      uri = URI.parse(url.to_s)
      return nil if override_origin?(uri)

      pinned = uri.scheme == "https" && PrivateAddressGuard.pinned_url(url)
      pinned ? pinned.last : raise(ItemFailed, "#{label} pointed the download at an address Disk does not fetch from")
    rescue URI::InvalidURIError
      raise ItemFailed, "#{label} gave a download address that is not a URL"
    end

    def override_origin?(uri)
      return false if Rails.env.production?

      prefix = "DISK_IMPORT_#{import.provider.to_s.upcase}_"
      ENV.any? do |k, v|
        next false unless k.start_with?(prefix) && k.end_with?("_URL") && v.present?

        o = URI.parse(v)
        [o.scheme, o.host, o.port] == [uri.scheme, uri.host, uri.port]
      rescue URI::InvalidURIError
        false
      end
    end

    def label = OauthProvider.label(import.provider)

    def forget_token! = connection.update!(access_token: nil)

    # A cached access token for the connection, fetched by the adapter when stale.
    def token
      return connection.access_token if connection.access_token_fresh?

      access, expires_in = fetch_token
      connection.store_access!(access, expires_in)
      access
    end

    # The refresh-token grant the member and Google/Dropbox org connections use.
    def refreshed_token
      tokens = OauthProvider.refresh_tokens(import.provider, connection.refresh_token,
                                            scope: Disk::ImportSource.scope(import.provider, connection.reach),
                                            client: Disk::ImportSource.client(import.provider))
      [tokens["access_token"], tokens["expires_in"]]
    rescue OauthProvider::Error => e
      raise unless e.message.include?("invalid_grant") || e.message.match?(/HTTP 40[01]/)

      raise Stop.new(Disk::Import::PAUSE_AUTHORIZATION,
                     "The #{label} authorisation was revoked or expired. Connect again, then resume.")
    end

    def tempfile = Tempfile.new(["disk-import", ".bin"], binmode: true)

    # A converted item is checked for a complete export in the expected
    # format: Office files are zip packages with a content-types part,
    # markdown is UTF-8, anything else is accepted when non-empty.
    def export_complete?(file, ext)
      file.rewind
      case ext.to_s.downcase
      when "xlsx", "pptx", "docx"
        head = file.read(4)
        file.rewind
        head == "PK\x03\x04".b && zip_has?(file, "[Content_Types].xml")
      when "md", "markdown" then file.read.force_encoding(Encoding::UTF_8).valid_encoding?
      else file.size.positive?
      end
    ensure
      file.rewind
    end

    private

    def target = import.target_node
    def actor = import.actor
    def ops = @ops ||= Disk::NodeOps.new(actor)
    def uploads = @uploads ||= Disk::UploadOps.new(actor)

    def item_rows
      Disk::ImportItem.where(organization_id: import.organization_id, provider: import.provider,
                             target_node_id: import.target_node_id)
    end

    def item_row(source_id) = item_rows.find_by(source_id: source_id)

    def throttled?(response)
      return true if [429, 503].include?(response.status)

      response.status == 403 && response.body.to_s.match?(/rateLimitExceeded|userRateLimitExceeded/)
    end

    def import_folder(row, item, parent)
      if (node = row.live_node)
        place!(row, node, item, parent)
      else
        node = ops.create_folder(parent_key: parent.key, name: safe_name(item), keep_both: true)
        note_rename(row, item, node)
        bump(:folders)
      end
      finish(row, item, Disk::ImportItem::STATUS_DONE, node: node)
      node
    end

    def import_content(row, item, parent)
      node = row.live_node
      if node && row.status == Disk::ImportItem::STATUS_DONE && row.source_modified_at == item.modified_at
        place!(row, node, item, parent)
        bump(:unchanged)
        finish(row, item, Disk::ImportItem::STATUS_DONE, node: node)
        return node
      end

      file = fetch_verified(item)
      reason = nil
      if item.kind == :page && file.size > Disk::Page::MAX_BYTES
        # Too big for a page: kept as the file it was exported as, never read into memory.
        item = item.dup.tap { |i| i.kind = :export }
        reason = PAGE_TOO_LARGE
      end
      # A re-run whose item switched between page and file writes a new node;
      # the old one goes to the Trash rather than staying live and stale.
      stale = node if node && node.page? != (item.kind == :page)
      node = nil if stale
      existing = node
      node = item.kind == :page ? write_page(row, node, item, parent, file) : write_file(row, node, item, parent, file)
      ops.trash(stale) if stale
      if existing then bump(:updated)
      else bump(item.kind == :page ? :pages : :files)
      end
      if item.kind == :file
        row.detail = row.detail.merge("hash_verified" => true).except("converted")
      else
        bump(:converted)
        row.detail = row.detail.merge("converted" => true, "format" => item.ext, "hash_verified" => false)
      end
      finish(row, item, Disk::ImportItem::STATUS_DONE, node: node, reason: reason)
      node
    ensure
      file&.close!
    end

    # Downloads (or exports) and verifies, retrying once; a second mismatch
    # fails the item and nothing is stored.
    def fetch_verified(item)
      2.times do
        file = item.kind == :file ? download(item) : export(item, item.format)
        return file if verify(item, file)

        file.close!
      end
      raise ItemFailed, item.kind == :file ? "The download did not match the source's hash, twice" :
                                              "The export was incomplete or not a valid #{item.ext} file, twice"
    end

    def write_file(row, node, item, parent, file)
      size = file.size
      sha = Digest::SHA256.file(file.path).hexdigest
      if node
        place!(row, node, item, parent)
        uploads.write(bytes: file, size: size, sha256: sha, node_key: node.key)
        node.reload
      else
        written, = uploads.write(bytes: file, size: size, sha256: sha, parent_key: parent.key, name: safe_name(item),
                                 on_conflict: "keep_both")
        note_rename(row, item, written)
        written
      end.tap { bump(:bytes, size) }
    end

    def write_page(row, node, item, parent, file)
      markdown = file.read.force_encoding(Encoding::UTF_8)
      if node&.page?
        place!(row, node, item, parent)
      else
        node = ops.create_folder(parent_key: parent.key, name: safe_name(item), keep_both: true,
                                 kind: Disk::Node::KIND_PAGE)
        note_rename(row, item, node)
      end
      ops.save_page(node, ydoc: nil, markdown: markdown, base_revision: Disk::Page.for(node).revision)
      node
    end

    # A rename or move at the source renames or moves the node, never a copy.
    def place!(row, node, item, parent)
      if node.parent_id != parent.id
        ops.move(node, target_key: parent.key, keep_both: true)
        row.detail = row.detail.merge("moved" => true)
        bump(:moved)
      end
      return if row.name == item.name

      ops.rename(node, safe_name(item), keep_both: true)
      bump(:renamed)
      note_rename(row, item, node)
    end

    # The name Disk can hold: no slashes or control characters, at most 255
    # characters, with the export's extension.
    def safe_name(item)
      name = item.name.to_s.gsub(%r{[/\\[:cntrl:]]}, "_").strip
      name = "_" if name.empty? || %w[. ..].include?(name)
      ext = item.kind == :export && item.ext ? ".#{item.ext}" : ""
      name = name.delete_suffix(ext) if ext.present? && name.downcase.end_with?(ext)
      "#{name[0, Disk::Node::NAME_MAX - ext.length]}#{ext}"
    end

    # The source name with the export's extension, before any change.
    def plain_name(item)
      ext = item.kind == :export && item.ext ? ".#{item.ext}" : ""
      item.name.to_s.downcase.end_with?(ext) ? item.name.to_s : "#{item.name}#{ext}"
    end

    # Records in the report when the name in Disk differs from the source's.
    def note_rename(row, item, node)
      detail = row.detail.except("renamed_from", "renamed_to", "rename_reason", "clashed_with")
      if node.name != plain_name(item)
        reason = node.name == safe_name(item) ? RENAME_ILLEGAL : RENAME_CLASH
        detail = detail.merge("renamed_from" => plain_name(item), "renamed_to" => node.name, "rename_reason" => reason)
        if reason == RENAME_CLASH
          other = Disk::Node.live.where(parent_id: node.parent_id).where.not(id: node.id)
            .find_by("lower(name) = lower(?)", safe_name(item))
          detail["clashed_with"] = other.name if other
        end
      end
      row.detail = detail
      row.name = item.name
    end

    PAGE_TOO_LARGE = "Over the #{Disk::Page::MAX_BYTES / 1.megabyte} MB page limit, so it was imported as a file".freeze
    RENAME_ILLEGAL = "Characters Disk does not allow in names were replaced".freeze
    RENAME_CLASH = "Another item in the folder has this name, ignoring case".freeze

    def finish(row, item, status, node: row.node, reason: nil)
      row.assign_attributes(import_id: import.id, name: row.name || item.name, source_modified_at: item.modified_at,
                            node_id: node&.id, status: status, reason: reason)
      # A source that reports a rename as "deleted at the old path, then present
      # at the new one" (Dropbox) was counted as a deletion a moment ago: undo it.
      bump(:deleted_at_source, -1) if @deleted_this_run&.delete?(row.id)
      row.detail = row.detail.except("deleted_at_source")
      row.detail = row.detail.merge("path" => item.path) if item.path
      bump(:skipped) if status == Disk::ImportItem::STATUS_SKIPPED
      bump(:failed) if status == Disk::ImportItem::STATUS_FAILED
      row.save!
    end

    # Deleted at the source: reported, nothing deleted in Disk.
    def deleted_at_source(item)
      row = item.id ? item_row(item.id) : item_rows.find_by("detail->>'path' = ?", item.path.to_s)
      return unless row

      row.update!(import_id: import.id, detail: row.detail.merge("deleted_at_source" => true))
      bump(:deleted_at_source) if (@deleted_this_run ||= Set.new).add?(row.id)
    end

    # Sharing at the source: members get a grant (or a share role on a share's
    # top), outsiders, groups that cannot be expanded and public links go to
    # the report and are not recreated.
    def share!(row, item, node)
      Array(permissions(item)).each { |perm| apply_permission(perm, node, row) }
    end

    # The shared space's own members become the share's members.
    def share_space!
      root = Item.new(id: root_id, kind: :folder, name: import.space_name)
      Array(permissions(root)).each { |perm| apply_permission(perm, target, nil) }
    end

    def apply_permission(perm, node, row)
      case perm.type
      when :link then row&.update!(detail: row.detail.merge("public_link" => true))
      when :group
        return tally("unresolved_groups", perm.name || perm.email) if perm.members.nil?

        perm.members.each { |email| grant(node, email, perm.role) }
      else grant(node, perm.email, perm.role)
      end
    end

    def grant(node, email, source_role)
      member = @members[email.to_s.downcase]
      return tally("unmatched_people", email.to_s.downcase) unless member
      return if member.id == actor.id || member.custodian_of?(node)

      role = ROLES[source_role.to_s.downcase] || Disk::ROLE_VIEW
      if node.root? && node.share_id
        sm = Disk::ShareMembership.find_or_initialize_by(share_id: node.share_id, membership_id: member.id)
        sm.update!(organization_id: node.organization_id, role: role) if sm.new_record? || Disk.role_rank(role) > Disk.role_rank(sm.role)
      else
        role = Disk::ROLE_EDIT if role == Disk::ROLE_MANAGE
        existing = node.grants.find_by(membership_id: member.id)
        ops.grant(node, member, role) unless existing && Disk.role_rank(existing.role) >= Disk.role_rank(role)
      end
      bump(:shared)
    end

    def tally(section, name)
      return if name.blank?

      list = (@report[section] ||= {})
      return unless list.key?(name) || list.size < REPORT_PEOPLE_MAX

      list[name] = list[name].to_i + 1
    end

    def bump(key, by = 1) = @counts[key.to_s] = @counts[key.to_s].to_i + by

    def checkpoint!(cursor)
      attrs = { counts: @counts, report: @report, updated_at: Time.current }
      attrs[:cursor] = cursor if cursor
      import.update_columns(attrs)
    end

    def pause!(reason, message)
      checkpoint!(nil)
      import.update!(state: Disk::Import::STATE_PAUSED, pause_reason: reason, error: message)
    end

    # Looks for a zip entry name in the central directory near the end of the
    # file, where every entry is listed.
    def zip_has?(file, entry)
      tail = [file.size, 1.megabyte].min
      file.seek(-tail, IO::SEEK_END)
      file.read.include?(entry)
    end
  end
end
