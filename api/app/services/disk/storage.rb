module Disk
  # The Disk bucket (docs/plans/disk-build.md sections 3 and 8), separate from
  # attachments. Browsers move the bytes through presigned URLs; Rails never
  # sees them. Server calls go to `endpoint`; URLs are signed for
  # `disk_public_endpoint`, the address a browser reaches. Object keys are
  # opaque: the org's public id and random hex, never a file name.
  class Storage
    Part = Struct.new(:number, :size, :etag, keyword_init: true)

    PART_URL_TTL = 15.minutes
    GET_URL_TTL = 5.minutes
    PUT_URL_TTL = 15.minutes
    DELETE_BATCH = 1000
    DESKTOP_ORIGINS = %w[tauri://localhost http://tauri.localhost https://tauri.localhost].freeze

    attr_reader :bucket, :provider

    ABORT_MULTIPART_DAYS = 2 # belt and braces next to Disk::ExpireUploadsJob

    def self.current = @current ||= new

    # What really differs between the stores Disk runs on (build guide 10b).
    #   path_style       path-style addressing (else virtual-hosted)
    #   region           forced region, nil = from settings
    #   checksums        aws-sdk request and response checksum mode
    #   ranged_disposition  response-content-disposition honoured on a 206
    #   create_bucket    the app key may create the bucket through the API
    #   copy_max         largest single CopyObject; above it, multipart copy
    #   equal_parts      every part but the last must be the same size
    # R2's ranged_disposition is unverified (its docs are silent); downloads are
    # full GETs, so nothing depends on it.
    PROVIDERS = {
      "garage" => { path_style: true, region: nil, checksums: "when_required", ranged_disposition: false,
                    create_bucket: true, copy_max: 5.gigabytes, equal_parts: false },
      "r2" => { path_style: true, region: "auto", checksums: "when_required", ranged_disposition: false,
                create_bucket: false, copy_max: 5.gigabytes, equal_parts: true },
      "s3" => { path_style: false, region: nil, checksums: "when_supported", ranged_disposition: true,
                create_bucket: true, copy_max: 5.gigabytes, equal_parts: false }
    }.freeze

    # The Disk bucket's own settings. DISK_STORAGE_PROVIDER picks a row of
    # PROVIDERS (garage in development and test, r2 in production, s3
    # supported). Keys and bucket fall back to the attachments store's
    # (config/storage.yml); so does the endpoint on Garage. On r2 and s3 the
    # endpoint is DISK_S3_ENDPOINT only, blank meaning AWS itself on s3.
    # DISK_S3_PUBLIC_ENDPOINT blank means the same address as the endpoint,
    # which R2 requires: presigned URLs work only on its S3 API endpoint.
    def self.config(env = ENV)
      base = Rails.application.config_for(:storage)
      name = env["DISK_STORAGE_PROVIDER"].presence || (Rails.env.production? ? "r2" : "garage")
      provider = PROVIDERS.fetch(name) { raise ArgumentError, "DISK_STORAGE_PROVIDER must be one of #{PROVIDERS.keys.join(', ')}" }
      pick = ->(key, fallback) { env.key?(key) ? env[key].presence : fallback }
      endpoint = name == "garage" ? pick.("DISK_S3_ENDPOINT", base[:endpoint]) : env["DISK_S3_ENDPOINT"].presence
      own_endpoint = env.key?("DISK_S3_ENDPOINT") || name != "garage"
      path_style = env.key?("DISK_S3_FORCE_PATH_STYLE") ? env["DISK_S3_FORCE_PATH_STYLE"].to_s == "true" : provider[:path_style]
      { provider: name, disk_bucket: env["DISK_S3_BUCKET"].presence || base[:disk_bucket],
        region: env["DISK_S3_REGION"].presence || provider[:region] || base[:region],
        endpoint: endpoint,
        disk_public_endpoint: pick.("DISK_S3_PUBLIC_ENDPOINT", own_endpoint ? endpoint : base[:disk_public_endpoint]) || endpoint,
        access_key_id: env["DISK_S3_ACCESS_KEY"].presence || base[:access_key_id],
        secret_access_key: env["DISK_S3_SECRET_KEY"].presence || base[:secret_access_key],
        force_path_style: path_style }
    end

    def self.new_key(organization) = "#{organization.key}/#{SecureRandom.hex(16)}"

    # Web origins allowed to talk to the bucket: DISK_CORS_ORIGINS, else the
    # API's own FRONTEND_URL list, plus the desktop webview.
    def self.cors_origins
      list = ENV["DISK_CORS_ORIGINS"].presence || ENV.fetch("FRONTEND_URL", "http://localhost:4173")
      list.split(",").map(&:strip).reject(&:empty?) + DESKTOP_ORIGINS
    end

    def initialize(config = self.class.config)
      if config[:access_key_id].blank? || config[:secret_access_key].blank?
        raise S3StorageService::ConfigurationError, "Object storage is not configured: set S3_ACCESS_KEY and S3_SECRET_KEY"
      end

      @bucket = config.fetch(:disk_bucket)
      @provider = config[:provider] || "garage"
      checksums = PROVIDERS.fetch(@provider)[:checksums]
      @region = config[:region] || "us-east-1"
      # Garage answers a ranged GET with the whole object's checksum, which the
      # SDK would reject, and R2 has refused the SDK's default CRC trailers:
      # those two send and check checksums only where an operation requires it.
      base = { region: @region, force_path_style: config[:force_path_style].to_s == "true",
               credentials: Aws::Credentials.new(config[:access_key_id], config[:secret_access_key]),
               request_checksum_calculation: checksums, response_checksum_validation: checksums }
      @client = Aws::S3::Client.new(**base, **endpoint(config[:endpoint]))
      public_client = Aws::S3::Client.new(**base, **endpoint(config[:disk_public_endpoint].presence || config[:endpoint]))
      @signer = Aws::S3::Presigner.new(client: public_client)
    end

    def create_multipart(key) = @client.create_multipart_upload(bucket: bucket, key: key).upload_id

    def part_url(key, upload_id, number)
      @signer.presigned_url(:upload_part, bucket: bucket, key: key, upload_id: upload_id, part_number: number,
                                          expires_in: PART_URL_TTL.to_i)
    end

    # The parts storage holds for a multipart upload. Raises
    # Aws::S3::Errors::NoSuchUpload once it is completed or aborted.
    def parts(key, upload_id)
      @client.list_parts(bucket: bucket, key: key, upload_id: upload_id).each_page.flat_map(&:parts).map do |p|
        Part.new(number: p.part_number, size: p.size, etag: p.etag)
      end
    end

    def complete_multipart(key, upload_id, parts)
      @client.complete_multipart_upload(
        bucket: bucket, key: key, upload_id: upload_id,
        multipart_upload: { parts: parts.sort_by(&:number).map { |p| { part_number: p.number, etag: p.etag } } }
      )
    end

    def abort_multipart(key, upload_id)
      @client.abort_multipart_upload(bucket: bucket, key: key, upload_id: upload_id)
    rescue Aws::S3::Errors::NoSuchUpload, Aws::S3::Errors::NotFound
      nil
    end

    # An empty file has no parts to upload; the API writes it.
    def put_empty(key) = @client.put_object(bucket: bucket, key: key, body: "")

    # Small writes the API makes itself (an agent's text file over MCP).
    def put_bytes(key, bytes) = @client.put_object(bucket: bucket, key: key, body: bytes)

    # A file on disk (an import's download): above MIN_PART_BYTES the SDK's
    # managed uploader sends it in equal parts read from the file in pieces,
    # every part but the last the same size, as R2 requires.
    def put_file(key, path)
      Aws::S3::Object.new(bucket_name: bucket, key: key, client: @client)
        .upload_file(path, multipart_threshold: Disk::Upload::MIN_PART_BYTES)
    end

    # The whole object into io (a Tempfile), for copying to the mail store.
    def read_into(key, io) = @client.get_object(bucket: bucket, key: key, response_target: io)

    # length bytes from offset, for an agent reading a text file in pages.
    def read_range(key, offset, length)
      return "".b if length <= 0

      @client.get_object(bucket: bucket, key: key, range: "bytes=#{offset}-#{offset + length - 1}").body.read
    rescue Aws::S3::Errors::InvalidRange
      "".b
    end

    # Object size in bytes, or nil when it does not exist.
    def size(key)
      @client.head_object(bucket: bucket, key: key).content_length
    rescue Aws::S3::Errors::NotFound, Aws::S3::Errors::NoSuchKey
      nil
    end

    # A short-lived GET that honours Range and always downloads as an attachment,
    # so nothing uploaded ever renders as a page.
    def get_url(key, filename: nil)
      disposition = ActionDispatch::Http::ContentDisposition.format(disposition: "attachment", filename: filename)
      @signer.presigned_url(:get_object, bucket: bucket, key: key, expires_in: GET_URL_TTL.to_i,
                                         response_content_disposition: disposition)
    end

    # A short-lived GET with no disposition override, for a viewer that reads
    # the bytes to preview them (a public link with downloads hidden). Objects
    # are stored as application/octet-stream, so nothing renders as a page.
    def preview_url(key) = @signer.presigned_url(:get_object, bucket: bucket, key: key, expires_in: GET_URL_TTL.to_i)

    # The origin presigned URLs point at (build guide 6.11), read off a
    # signed URL so it follows the provider's addressing.
    def origins = [URI.parse(preview_url("origin")).then { |u| "#{u.scheme}://#{u.host}#{":#{u.port}" unless u.port == u.default_port}" }]

    def put_url(key) = @signer.presigned_url(:put_object, bucket: bucket, key: key, expires_in: PUT_URL_TTL.to_i)

    def copy(source_key, target_key, size)
      opts = size > PROVIDERS.fetch(provider)[:copy_max] ? { multipart_copy: true, content_length: size } : {}
      Aws::S3::Object.new(bucket_name: bucket, key: source_key, client: @client)
        .copy_to({ bucket: bucket, key: target_key }, **opts)
    end

    def delete(keys)
      keys.compact.each_slice(DELETE_BATCH) do |batch|
        @client.delete_objects(bucket: bucket, delete: { objects: batch.map { |k| { key: k } }, quiet: true })
      end
    end

    # Yields [key, size, last_modified] for every object in the bucket.
    def each_object
      @client.list_objects_v2(bucket: bucket).each_page do |page|
        page.contents.each { |o| yield o.key, o.size, o.last_modified }
      end
    end

    # [[key, upload_id, initiated], ...] for multipart uploads storage still holds open.
    def open_multiparts
      @client.list_multipart_uploads(bucket: bucket).each_page.flat_map(&:uploads)
        .map { |u| [u.key, u.upload_id, u.initiated] }
    end

    # Idempotent: creates the bucket where the store lets this key do so (AWS
    # wants a location constraint outside us-east-1), sets CORS for the web
    # origins, and asks storage to drop multipart uploads left open for
    # ABORT_MULTIPART_DAYS (rake disk:storage:setup).
    def setup!(origins = self.class.cors_origins)
      begin
        if PROVIDERS.fetch(provider)[:create_bucket]
          location = %w[us-east-1 garage auto].include?(@region) ? {} : { create_bucket_configuration: { location_constraint: @region } }
          @client.create_bucket(bucket: bucket, **location)
        end
      rescue Aws::S3::Errors::BucketAlreadyOwnedByYou, Aws::S3::Errors::BucketAlreadyExists
        nil
      rescue Aws::S3::Errors::ServiceError => e
        Rails.logger.warn("[Disk::Storage] could not create #{bucket}: #{e.message}")
      end
      # One rule per origin: given several origins in one rule, Garage answers with
      # all of them joined in Access-Control-Allow-Origin, which browsers reject.
      @client.put_bucket_cors(bucket: bucket, cors_configuration: { cors_rules: origins.map { |origin|
        { allowed_origins: [origin], allowed_methods: %w[GET HEAD PUT], allowed_headers: %w[range content-type], # browsers send them lowercased; Garage matches case-sensitively
          expose_headers: %w[ETag Content-Length Content-Range Accept-Ranges], max_age_seconds: 3600 }
      } })
      @client.put_bucket_lifecycle_configuration(bucket: bucket, lifecycle_configuration: { rules: [{
        id: "abort-incomplete-multipart", status: "Enabled", filter: { prefix: "" },
        abort_incomplete_multipart_upload: { days_after_initiation: ABORT_MULTIPART_DAYS }
      }] })
    rescue Aws::S3::Errors::NotImplemented, Aws::S3::Errors::MalformedXML => e
      Rails.logger.warn("[Disk::Storage] #{bucket} takes no lifecycle rule (#{e.class}); ExpireUploadsJob still aborts")
    end

    def lifecycle_rules = @client.get_bucket_lifecycle_configuration(bucket: bucket).rules

    def cors_rules = @client.get_bucket_cors(bucket: bucket).cors_rules

    private

    def endpoint(url) = url.present? ? { endpoint: url } : {}
  end
end
