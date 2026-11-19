# One organisation data export (spec 11.3.3, A15.6): a .zip of every domain's
# mail as mbox plus every calendar as .ics, built by DataExportJob and kept in
# object storage for RETENTION. docs/Reference-Implementation.md "Data export".
class DataExport < ApplicationRecord
  key_prefix "dex"

  STATUS_QUEUED = "queued".freeze
  STATUS_RUNNING = "running".freeze
  STATUS_READY = "ready".freeze
  STATUS_FAILED = "failed".freeze
  STATUS_EXPIRED = "expired".freeze
  STATUSES = [STATUS_QUEUED, STATUS_RUNNING, STATUS_READY, STATUS_FAILED, STATUS_EXPIRED].freeze
  # In flight. A partial unique index allows one of these per org at a time.
  ACTIVE_STATUSES = [STATUS_QUEUED, STATUS_RUNNING].freeze

  RETENTION = 7.days
  # A worker killed mid-build leaves the row `running` forever, which would block
  # every later export. fail_stale! (on request + in the sweep) fails anything in
  # flight this long.
  STALE_AFTER = 6.hours

  belongs_to :organization
  belongs_to :requested_by, class_name: "Membership", foreign_key: :requested_by_membership_id, optional: true

  validates :status, inclusion: { in: STATUSES }

  scope :active, -> { where(status: ACTIVE_STATUSES) }

  def ready? = status == STATUS_READY
  def expired? = status == STATUS_EXPIRED || (ready? && expires_at.present? && expires_at <= Time.current)

  def filename
    "inbox2-export-#{organization.slug.presence || organization.key}-#{created_at.utc.strftime('%Y%m%d')}.zip"
  end

  # Daily sweep (config/recurring.yml): drop the file of every export past its
  # expiry, and fail exports whose worker died.
  def self.sweep!(now: Time.current)
    where(status: STATUS_READY).where(expires_at: ..now).find_each do |export|
      S3StorageService.new.delete(export.storage_key) if export.storage_key.present?
      export.update!(status: STATUS_EXPIRED, storage_key: nil)
    rescue S3StorageService::ConfigurationError, Aws::Errors::ServiceError, Seahorse::Client::NetworkingError => e
      Rails.logger.error("[DataExport] could not purge #{export.key}: #{e.class}: #{e.message}")
    end
    fail_stale!(now: now)
  end

  def self.fail_stale!(now: Time.current)
    active.where(updated_at: ..(now - STALE_AFTER))
          .update_all(status: STATUS_FAILED, error: "The export stopped before it finished. Start a new one.", updated_at: now)
  end
end
