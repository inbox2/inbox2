module Disk
  # Makes a version's thumbnail on the server (Disk::Thumbnailer). Enqueued a
  # little after each new version so the browser's own thumbnail usually lands
  # first and this finds nothing to do. A file that will not decode keeps its
  # type icon; there is no retry.
  class ThumbnailJob < ApplicationJob
    queue_as :default

    DELAY = 30.seconds

    def perform(version_id)
      version = Disk::Version.includes(:node).find_by(id: version_id)
      return unless version&.current?

      Disk::Thumbnailer.new(version).run
    rescue Disk::Thumbnailer::Failed, Aws::Errors::ServiceError, Seahorse::Client::NetworkingError => e
      Rails.logger.warn("[Disk::ThumbnailJob] #{version_id}: #{e.message}")
    end
  end
end
