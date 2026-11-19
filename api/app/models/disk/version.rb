module Disk
  # One stored version of a file. The current one is the node's
  # current_version; older ones expire RETAIN_DAYS after they are replaced
  # (spec F2). Sealed versions carry their wrapped key and manifest.
  class Version < ApplicationRecord
    key_prefix "dvr"

    RETAIN_DAYS = 180
    VARIANT_THUMBNAIL = "thumbnail".freeze
    VARIANT_RENDITION = "rendition".freeze
    VARIANTS = [VARIANT_THUMBNAIL, VARIANT_RENDITION].freeze

    belongs_to :organization
    belongs_to :node, class_name: "Disk::Node"
    belongs_to :author, class_name: "Membership", foreign_key: :author_membership_id, optional: true

    def current? = node.current_version_id == id
    def sealed? = wrapped_key.present?

    # Derived objects sit beside the version's own object and do not count toward quota.
    def variant_key(variant) = "#{storage_key}.#{variant}"

    # Returns these versions' bytes to their orgs' quota and deletes their
    # objects once the surrounding transaction commits. The caller deletes the
    # rows (directly, or by deleting their nodes) in the same transaction.
    def self.release!(scope)
      rows = scope.pluck(:organization_id, :size_bytes, :storage_key, :thumbnail_storage_key, :rendition_storage_key)
      return if rows.empty?

      rows.group_by(&:first).each { |org_id, rs| Disk::Quota.move!(org_id, used: -rs.sum { |r| r[1] }) }
      keys = rows.flat_map { |r| r[2..] }.compact
      ActiveRecord.after_all_transactions_commit { delete_objects(keys) }
    end

    # A failed delete leaves an orphan for the reconcile job to report; the rows are already gone.
    def self.delete_objects(keys)
      Disk::Storage.current.delete(keys)
    rescue Aws::Errors::ServiceError, Seahorse::Client::NetworkingError => e
      Rails.logger.warn("[Disk] could not delete #{keys.size} objects: #{e.message}")
    end
  end
end
