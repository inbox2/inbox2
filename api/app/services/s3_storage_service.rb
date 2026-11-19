# S3-compatible object storage service for attachments (spec 16.5.2, A7.2, A7.3).
#
# Wraps aws-sdk-s3 for upload, download, signed URLs, and deletion.
# Configured via config/storage.yml — works with Garage, AWS S3, or any
# S3-compatible service.
#
# Usage:
#   service = S3StorageService.new
#   key = service.upload(data, filename: "report.pdf", content_type: "application/pdf")
#   url = service.presigned_url(key, expires_in: 3600)
#   data = service.download(key)
#   service.delete(key)
class S3StorageService
  # Raised when the environment carries no credentials. A clear error at the
  # boundary beats an opaque KeyError from the config file (or, worse, an
  # anonymous client that 403s on every call).
  class ConfigurationError < StandardError; end

  def initialize
    @config = load_config
    missing = %w[access_key_id secret_access_key].select { |k| @config[k].blank? }
    if missing.any?
      raise ConfigurationError,
            "Object storage is not configured: set #{missing.map { |k| "S3_#{k.sub('_id', '').upcase}" }.join(' and ')}"
    end
    @client = Aws::S3::Client.new(client_options)
    ensure_bucket
  end

  # Upload binary data and return the storage key.
  def upload(data, filename:, content_type: "application/octet-stream", organization_key: nil)
    key = generate_key(filename, organization_key)

    @client.put_object(
      bucket: bucket,
      key: key,
      body: data,
      content_type: content_type
    )

    key
  end

  # Generate a presigned download URL valid for the given duration.
  def presigned_url(key, expires_in: 3600)
    signer = Aws::S3::Presigner.new(client: @client)
    signer.presigned_url(:get_object, bucket: bucket, key: key, expires_in: expires_in)
  end

  # Download the object and return raw bytes.
  def download(key)
    response = @client.get_object(bucket: bucket, key: key)
    response.body.read
  end

  # Download an object, returning [bytes, content_type] from the stored metadata.
  def download_with_type(key)
    response = @client.get_object(bucket: bucket, key: key)
    [response.body.read, response.content_type]
  end

  # Stream an object in chunks without holding it in memory (large exports).
  def stream(key, &block)
    @client.get_object(bucket: bucket, key: key, &block)
  end

  # Delete an object from storage.
  def delete(key)
    @client.delete_object(bucket: bucket, key: key)
  end

  # Check if an object exists.
  def exists?(key)
    @client.head_object(bucket: bucket, key: key)
    true
  rescue Aws::S3::Errors::NotFound
    false
  end

  private

  def bucket
    @config["bucket"]
  end

  def client_options
    opts = {
      region: @config["region"] || "us-east-1",
      force_path_style: @config["force_path_style"].to_s == "true",
      credentials: Aws::Credentials.new(
        @config["access_key_id"],
        @config["secret_access_key"]
      )
    }
    opts[:endpoint] = @config["endpoint"] if @config["endpoint"].present?
    opts
  end

  def ensure_bucket
    @client.head_bucket(bucket: bucket)
  rescue Aws::S3::Errors::NotFound, Aws::S3::Errors::NoSuchBucket
    @client.create_bucket(bucket: bucket)
    Rails.logger.info("[S3StorageService] Created bucket #{bucket}")
  rescue Aws::Errors::ServiceError => e
    Rails.logger.warn("[S3StorageService] Bucket check failed: #{e.message} (storage may not be available)")
  end

  def generate_key(filename, organization_key)
    org_prefix = organization_key || "global"
    date_prefix = Time.current.strftime("%Y/%m/%d")
    unique_id = SecureRandom.hex(8)
    safe_filename = filename.gsub(/[^\w.\-]/, "_")

    "#{org_prefix}/#{date_prefix}/#{unique_id}/#{safe_filename}"
  end

  def load_config
    config_path = Rails.root.join("config", "storage.yml")
    all_config = YAML.safe_load(ERB.new(File.read(config_path)).result, aliases: true)
    all_config.fetch(Rails.env, all_config.fetch("default", {}))
  end
end
