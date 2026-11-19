module Disk
  # A folder, file or page, on a member's C:\ (custodian_membership_id) or in a
  # share on D:\ (share_id). Each drive has one parentless root folder.
  # Sealed nodes carry metadata_ciphertext instead of name and mime.
  class Node < ApplicationRecord
    key_prefix "dnd"

    KIND_FOLDER = "folder".freeze
    KIND_FILE = "file".freeze
    KIND_PAGE = "page".freeze
    KINDS = [KIND_FOLDER, KIND_FILE, KIND_PAGE].freeze

    NAME_MAX = 255
    UNIQUE_NAME_INDEX = "index_disk_nodes_unique_name_in_folder".freeze

    # Type-family filter (spec F2). MIME patterns for SQL LIKE; "documents"
    # excludes what "sheets" claims (text/csv), "other" is any file outside them all.
    FAMILY_MIMES = {
      "sheets" => ["text/csv", "application/vnd.ms-excel", "application/vnd.openxmlformats-officedocument.spreadsheetml.%",
                   "application/vnd.oasis.opendocument.spreadsheet"],
      "slides" => ["application/vnd.ms-powerpoint", "application/vnd.openxmlformats-officedocument.presentationml.%",
                   "application/vnd.oasis.opendocument.presentation"],
      "documents" => ["application/pdf", "application/msword", "application/rtf", "text/%",
                      "application/vnd.openxmlformats-officedocument.wordprocessingml.%",
                      "application/vnd.oasis.opendocument.text"],
      "images" => ["image/%"],
      "media" => ["video/%", "audio/%"]
    }.freeze
    FAMILIES = (%w[folders pages other] + FAMILY_MIMES.keys).freeze

    class NameTaken < StandardError; end

    belongs_to :organization
    belongs_to :share, class_name: "Disk::Share", optional: true
    belongs_to :custodian, class_name: "Membership", foreign_key: :custodian_membership_id, optional: true
    belongs_to :parent, class_name: "Disk::Node", optional: true
    belongs_to :created_by, class_name: "Membership", foreign_key: :created_by_membership_id, optional: true
    belongs_to :modified_by, class_name: "Membership", foreign_key: :modified_by_membership_id, optional: true
    belongs_to :trashed_by, class_name: "Membership", foreign_key: :trashed_by_membership_id, optional: true
    has_many :children, class_name: "Disk::Node", foreign_key: :parent_id
    has_many :grants, class_name: "Disk::Grant"
    has_many :versions, class_name: "Disk::Version"
    belongs_to :current_version, class_name: "Disk::Version", optional: true
    has_one :page, class_name: "Disk::Page"

    validates :kind, inclusion: { in: KINDS }
    validate :name_is_valid, unless: -> { sealed? || root? }

    before_validation { self.name = name.strip if name.is_a?(String) }

    scope :live, -> { where(trashed_at: nil) }

    # The public id without its prefix, for URLs (`.../Logos-<short_id>`).
    # Nanoid's alphabet is URL-safe; it may contain "-" and "_", so a client
    # splitting "<name>-<short_id>" takes the last SHORT_ID_LENGTH characters.
    SHORT_ID_LENGTH = 21

    def short_id = key&.delete_prefix("#{self.class.key_prefix}_")

    # Accepts "dnd_xxx" or the bare short id.
    def self.key_for(ref)
      ref = ref.to_s
      ref.start_with?("#{key_prefix}_") ? ref : "#{key_prefix}_#{ref}"
    end

    # The person's C:\ root folder, made on first use: in their personal
    # workspace, with its membership as custodian (the same from every team).
    def self.c_root_for(member_or_user)
      user = member_or_user.is_a?(User) ? member_or_user : member_or_user.user
      custodian = user.personal_membership
      attrs = { organization_id: custodian.organization_id, custodian_membership_id: custodian.id, parent_id: nil }
      find_by(attrs) || create!(attrs.merge(kind: KIND_FOLDER))
    rescue ActiveRecord::RecordNotUnique
      find_by!(attrs)
    end

    def root? = parent_id.nil?
    def folder? = kind == KIND_FOLDER
    def page? = kind == KIND_PAGE
    # Folders hold anything; pages hold sub-pages (the page tree, spec F6).
    def container? = folder? || page?
    def trashed? = trashed_at.present?
    def on_c_drive? = custodian_membership_id.present?

    # Saves, resolving a name clash in this folder. keep_both picks "a (1).pdf";
    # otherwise a clash raises NameTaken. The suffix is chosen and inserted in
    # one savepoint and retried on a unique violation, so racing writers both land.
    def save_with_unique_name!(keep_both: false)
      base = name
      attempt = 0
      if keep_both
        attempt += 1 while sibling_name_taken?(attempt.zero? ? base : self.class.suffixed(base, attempt, folder?))
        self.name = self.class.suffixed(base, attempt, folder?) unless attempt.zero?
      end
      begin
        self.class.transaction(requires_new: true) { save! }
      rescue ActiveRecord::RecordNotUnique => e
        raise unless e.message.include?(UNIQUE_NAME_INDEX)
        raise NameTaken, base unless keep_both

        attempt += 1
        self.name = self.class.suffixed(base, attempt, folder?)
        retry
      end
      self
    end

    def sibling_name_taken?(candidate)
      Node.live.where(parent_id: parent_id).where.not(id: id)
        .where("lower(name) = lower(?)", candidate).exists?
    end

    # "a.pdf" -> "a (1).pdf"; folders keep dots in their name.
    def self.suffixed(name, n, folder = false)
      return name if n.zero?

      ext = folder ? "" : File.extname(name)
      ext = "" if ext == name # ".env"
      "#{name.delete_suffix(ext)} (#{n})#{ext}"
    end

    # Ids of these nodes and everything beneath them. With skip_trash_roots,
    # does not descend into (or include) nodes deleted on their own, so a
    # restore leaves separately trashed children in the trash.
    # `ids` is an array or a relation selecting one id column.
    def self.subtree_ids_sql(ids, skip_trash_roots: false)
      step = skip_trash_roots ? "AND NOT n.trash_root" : ""
      seeds = ids.is_a?(ActiveRecord::Relation) ? ids.to_sql : sanitize_sql(["?", Array(ids).presence || [nil]])
      <<~SQL.squish
        WITH RECURSIVE t(id) AS (
          SELECT id FROM disk_nodes WHERE id IN (#{seeds})
          UNION ALL
          SELECT n.id FROM disk_nodes n JOIN t ON n.parent_id = t.id #{step}
        ) SELECT id FROM t
      SQL
    end

    # Adds delta to folder and every folder above it: a folder's size_bytes is
    # the sum of the live files beneath it. ponytail: one recursive update per
    # change; batch per folder if bulk uploads make this hot.
    def self.add_size!(folder, delta)
      return if folder.nil? || delta.zero?

      where(<<~SQL.squish, folder.id).update_all(["size_bytes = size_bytes + ?", delta])
        id IN (WITH RECURSIVE a(id, parent_id) AS (
          SELECT id, parent_id FROM disk_nodes WHERE id = ?
          UNION ALL
          SELECT n.id, n.parent_id FROM disk_nodes n JOIN a ON n.id = a.parent_id
        ) SELECT id FROM a)
      SQL
    end

    # Makes a new current version of this file (inside the caller's
    # transaction): the old one starts its retention clock, the node takes the
    # new size and the folders above it follow.
    def add_version!(author:, storage_key:, size_bytes:, **attrs)
      lock!
      previous = current_version
      version = versions.create!(organization_id: organization_id, number: versions.maximum(:number).to_i + 1,
                                 storage_key: storage_key, size_bytes: size_bytes, author: author, **attrs)
      previous&.update!(expires_at: Disk::Version::RETAIN_DAYS.days.from_now)
      delta = size_bytes - self.size_bytes
      update!(current_version: version, size_bytes: size_bytes, modified_by: author, content_modified_at: Time.current)
      self.class.add_size!(parent, delta)
      unless version.sealed?
        ActiveRecord.after_all_transactions_commit { Disk::ThumbnailJob.set(wait: Disk::ThumbnailJob::DELAY).perform_later(version.id) }
      end
      version
    end

    # A sealed scope's own root: a sealed share's top folder or a sealed C:\ folder.
    def scope_root? = sealed? && seal_scope_node_id == id
    # Staged by the client and not yet switched in (build guide 6.8).
    def pending? = pending_until.present?

    # Every sealed write (build guide 6.7), inside the committing transaction:
    # locks the scope root, then refuses while rotation is due, for a writer
    # holding no key for the current epoch, and for any epoch but the current
    # one. epoch nil skips that last check (moves and restores write no new
    # ciphertext). nil when the write may go ahead.
    def write_refusal(membership, epoch = nil)
      root = seal_scope_node_id && self.class.lock.find_by(id: seal_scope_node_id)
      return Disk::Refused.new("This sealed item has no key") unless root
      if root.rotation_due
        return Disk::Refused.new("A key holder left this sealed folder. A manager must renew its key first.", status: 409, code: Disk::Sealing::ROTATION_REQUIRED,
                                                  current_epoch: root.scope_epoch)
      end
      unless Disk::KeyGrant.exists?(scope_node_id: root.id, membership_id: membership.disk_ids, epoch: root.scope_epoch)
        return Disk::Refused.new("You hold no key for this sealed folder", status: 403)
      end
      return if epoch.nil? || epoch == root.scope_epoch

      Disk::Refused.new("This folder's key changed. Try again.",
                        status: 409, code: Disk::Sealing::EPOCH_CHANGED, current_epoch: root.scope_epoch)
    end

    def write_check!(membership, epoch = nil)
      refusal = write_refusal(membership, epoch)
      raise refusal if refusal
    end

    def self.subtree(ids, **opts) = where("disk_nodes.id IN (#{subtree_ids_sql(ids, **opts)})")

    # { node_id => [root, ..., node] } for each node, in one recursive query.
    def self.paths_for(nodes)
      nodes = Array(nodes)
      return {} if nodes.empty?

      rows = connection.select_rows(sanitize_sql([<<~SQL.squish, nodes.map(&:id)]))
        WITH RECURSIVE a(start_id, id, parent_id, depth) AS (
          SELECT id, id, parent_id, 0 FROM disk_nodes WHERE id IN (?)
          UNION ALL
          SELECT a.start_id, n.id, n.parent_id, a.depth + 1 FROM disk_nodes n JOIN a ON n.id = a.parent_id
        ) SELECT start_id, id, depth FROM a
      SQL
      by_id = where(id: rows.map { |r| r[1] }.uniq).includes(:share).index_by(&:id)
      rows.group_by(&:first).transform_values do |chain|
        chain.sort_by { |r| -r[2] }.map { |r| by_id[r[1]] }
      end
    end

    def path = self.class.paths_for(self)[id]

    def self.of_family(family)
      case family
      when "folders" then where(kind: KIND_FOLDER)
      when "pages" then where(kind: KIND_PAGE)
      when "documents"
        files.where("mime LIKE ANY (ARRAY[?])", FAMILY_MIMES["documents"])
          .where.not("mime LIKE ANY (ARRAY[?])", FAMILY_MIMES["sheets"])
      when "other"
        files.where("mime IS NULL OR NOT mime LIKE ANY (ARRAY[?])", FAMILY_MIMES.values.flatten)
      else files.where("mime LIKE ANY (ARRAY[?])", FAMILY_MIMES.fetch(family))
      end
    end

    def self.files = where(kind: KIND_FILE, sealed: false)

    private

    def name_is_valid
      if name.blank?
        errors.add(:name, "can't be blank")
      elsif name.length > NAME_MAX
        errors.add(:name, "is too long (maximum is #{NAME_MAX} characters)")
      elsif name.match?(%r{[/\\[:cntrl:]]}) || %w[. ..].include?(name)
        errors.add(:name, "can't contain slashes or invisible characters")
      end
    end
  end
end
