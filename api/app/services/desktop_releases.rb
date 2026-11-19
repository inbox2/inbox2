# Desktop releases, read from the Pushleft bucket bin/release-desktop uploads to.
#
# Layout (produced by ui/desktop/scripts/build-release.mjs):
#   <bucket>/<version>/Inbox2_<v>_universal.dmg, *-setup.exe, *.AppImage,
#                      *.deb, *.rpm, *.sig, latest.json
#
# The bucket is private. Rails keeps the public URLs (api.inbox2.com/downloads/
# desktop/...) and redirects each binary to a short-lived presigned GET, so
# manifests already in the field keep working. The api role no longer holds a
# volume, which is what made every api deploy stop-before-start (2026-11-16).
# This service backs three endpoints (see DesktopReleasesController):
#   - the Tauri updater manifest (short-cache passthrough of <version>/latest.json)
#   - the binary redirect
#   - the /console download list (per-OS installer files of the newest version)
module DesktopReleases
  # Bucket coordinates are not secret (.pl.yaml env); the key pair is.
  def self.bucket = ENV.fetch("DESKTOP_S3_BUCKET", "inbox2-desktop-downloads")

  def self.client
    @client ||= Aws::S3::Client.new(
      endpoint: ENV.fetch("DESKTOP_S3_ENDPOINT", "https://s3.pushleft.dev"),
      region: ENV.fetch("DESKTOP_S3_REGION", "garage"),
      force_path_style: true,
      access_key_id: ENV["DESKTOP_S3_ACCESS_KEY"],
      secret_access_key: ENV["DESKTOP_S3_SECRET_KEY"]
    )
  end

  def self.configured? = ENV["DESKTOP_S3_ACCESS_KEY"].present?

  # Public base for download URLs. API_PUBLIC_URL is the canonical external API
  # origin (also used by serializers for brand URLs).
  def self.public_base
    "#{ENV.fetch('API_PUBLIC_URL', 'http://localhost:4000')}/downloads/desktop"
  end

  # Every object in the bucket as { "<version>/<file>" => size }. The updater
  # polls every two minutes from every client, so the listing is cached for as
  # long as the manifest's own max-age.
  def self.objects
    return {} unless configured?

    Rails.cache.fetch("desktop_releases/objects", expires_in: 60.seconds) do
      client.list_objects_v2(bucket: bucket).each_page.flat_map(&:contents).to_h { |o| [o.key, o.size] }
    end
  end

  def self.read(key)
    client.get_object(bucket: bucket, key: key).body.read
  rescue Aws::S3::Errors::NoSuchKey
    nil
  end

  # A 15-minute GET for one release file, or nil when it isn't in the bucket.
  def self.download_url(version, file)
    key = "#{version}/#{file}"
    return nil unless objects.key?(key)

    Aws::S3::Presigner.new(client: client).presigned_url(:get_object, bucket: bucket, key: key, expires_in: 900)
  end

  # Newest available version (stable preferred over prerelease), or nil if none.
  #
  # A release only counts once its manifest is in place. bin/release-desktop
  # uploads the bundles first and `latest.json` LAST, so a version without one
  # is a publish still in flight — ranking it would 404 this endpoint (and fail
  # every running client's update check with "could not fetch a valid release
  # JSON") for the minutes an upload takes. Skipping it keeps serving the
  # previous release until the new one is whole, so a release appears atomically.
  def self.latest_version
    versions = objects.keys.filter_map { |k| k.delete_suffix("/latest.json") if k.end_with?("/latest.json") }
    versions = versions.select { |v| v =~ /\A\d+\.\d+\.\d+/ && !v.include?("/") }
    return nil if versions.empty?

    stable = versions.reject { |v| v.include?("-") }
    (stable.presence || versions).max_by { |v| version_key(v) }
  end

  # Sortable key: [major, minor, patch, prerelease?]. A stable release sorts
  # above its prereleases (1 > 0 in the 4th slot).
  def self.version_key(v)
    core, pre = v.split("-", 2)
    nums = core.split(".").map(&:to_i)
    nums + [pre ? 0 : 1, pre.to_s]
  end

  # Raw Tauri updater manifest JSON for a version (string), or nil if absent.
  def self.manifest_json(version)
    read("#{version}/latest.json")
  end

  # Maps an installer filename to a human OS + label, or nil if it isn't a
  # user-facing installer (e.g. the .app.tar.gz / .sig updater artifacts).
  INSTALLER_KINDS = {
    /\.dmg\z/i      => { os: "macos", label: "macOS", kind: "dmg" },
    /setup\.exe\z/i => { os: "windows", label: "Windows", kind: "exe" },
    /\.appimage\z/i => { os: "linux", label: "Linux · AppImage", kind: "appimage" },
    /\.deb\z/i      => { os: "linux", label: "Linux · deb", kind: "deb" },
    /\.rpm\z/i      => { os: "linux", label: "Linux · rpm", kind: "rpm" }
  }.freeze

  # Per-OS installer downloads for a version. Returns an array of hashes:
  #   { os:, label:, kind:, filename:, url:, size: }
  def self.downloads(version)
    objects.filter_map do |key, size|
      v, name = key.split("/", 2)
      next unless v == version && name && !name.include?("/")

      kind = INSTALLER_KINDS.find { |re, _| name =~ re }&.last
      next unless kind

      {
        os: kind[:os],
        label: kind[:label],
        kind: kind[:kind],
        filename: name,
        url: "#{public_base}/#{version}/#{name}",
        size: size
      }
    end.sort_by { |d| [%w[macos windows linux].index(d[:os]) || 9, d[:label]] }
  end

  # PORO the serializer renders for the /console download card.
  Release = Struct.new(:version, :pub_date, :downloads, keyword_init: true)

  def self.latest
    version = latest_version
    return nil unless version

    manifest = manifest_json(version)
    pub_date = manifest ? (JSON.parse(manifest)["pub_date"] rescue nil) : nil
    Release.new(version: version, pub_date: pub_date, downloads: downloads(version))
  end
end
