module Disk
  # An import run and its progress (spec F10). counts keys: seen, folders,
  # files, pages, converted, updated, unchanged, moved, renamed, skipped,
  # failed, deleted_at_source, shared, bytes.
  class ImportSerializer < ::ApplicationSerializer
    attributes :provider, :space_kind, :space_name, :source_email, :state, :pause_reason, :error,
               :counts, :created_at, :started_at, :finished_at

    attribute :target_id do |i|
      i.target_node&.key
    end

    attribute :share_id do |i|
      i.share&.key
    end

    # Set while the source holds this tenant after a throttle response.
    attribute :waiting_until do |i|
      i.connection&.waiting_until if i.queued?
    end

    attribute :resumable, &:resumable?

    one :owner, resource: Disk::MemberRefSerializer
    one :membership, key: :started_by, resource: Disk::MemberRefSerializer
  end
end
