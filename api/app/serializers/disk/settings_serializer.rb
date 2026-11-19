module Disk
  # Org-wide Disk settings a member's client needs (the organization), with
  # where the org stands in the downgrade lifecycle (spec F8): state is
  # active, read_only or blocked; the dates are set while the plan lacks Disk.
  class SettingsSerializer
    include Alba::Resource

    attribute :links_enabled, &:disk_links_enabled

    # Whether the plan includes sealing (E2EE): the client offers Seal only then.
    attribute :sealing_enabled, &:e2ee_entitled?

    # Above this a composer offers to send the file as a Disk link (spec F9).
    attribute :mail_attachment_limit_bytes, &:effective_mail_size_limit

    attribute :state do |o|
      o.disk_state.to_s
    end

    attribute :read_only_until do |o|
      o.disk_lost_at && (o.disk_lost_at + Organization::DISK_READ_ONLY_DAYS.days)
    end

    # Origins presigned URLs point at; the Disk service worker fetches from
    # these and refuses any other (build guide 6.11).
    attribute :storage_origins do |_o|
      Disk::Storage.current.origins
    end

    attribute :purge_at do |o|
      o.disk_lost_at && (o.disk_lost_at + Organization::DISK_PURGE_DAYS.days)
    end
  end
end
