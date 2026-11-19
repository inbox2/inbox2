namespace :disk do
  namespace :storage do
    desc "Create the Disk bucket where the store allows it and set CORS for the web origins (idempotent)"
    task setup: :environment do
      storage = Disk::Storage.new
      storage.setup!
      puts "Disk bucket #{storage.bucket}: CORS allows #{Disk::Storage.cors_origins.join(', ')}"
    end
  end

  desc "Queue server-side thumbnails for current unsealed files that have none (images, RAW, PDF, video)"
  task thumbnails: :environment do
    scope = Disk::Version.joins(:node).where("disk_nodes.current_version_id = disk_versions.id")
      .where(thumbnail_storage_key: nil, wrapped_key: nil)
    count = 0
    scope.includes(:node).find_each do |v|
      next unless Disk::Thumbnailer.kind(v.node.name)

      Disk::ThumbnailJob.perform_later(v.id)
      count += 1
    end
    puts "Queued #{count} thumbnails"
  end
end
