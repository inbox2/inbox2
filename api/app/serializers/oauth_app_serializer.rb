class OauthAppSerializer < ::ApplicationSerializer
  attributes :name, :redirect_uris, :created_at

  # The icon is stored as an internal S3 key; expose the public endpoint that
  # streams it, so it loads in a plain <img> on the consent screen (which has no
  # inbox2 session at all). nil when unset → the client falls back to initials.
  attribute :icon_url do |app|
    app.icon_url.present? ? OauthAppSerializer.icon_url(app) : nil
  end

  def self.icon_url(app)
    base = ENV.fetch("API_PUBLIC_URL", "http://localhost:4000")
    "#{base}/api/v1/oauth/apps/#{app.key}/icon?v=#{Digest::SHA1.hexdigest(app.icon_url.to_s)[0, 10]}"
  end
end
