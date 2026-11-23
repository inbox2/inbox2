class UserSerializer < ::ApplicationSerializer
  attributes :username, :display_name, :default_timezone, :default_language,
             :out_of_office_start, :out_of_office_end, :out_of_office_message

  # A person's own sign-up address (often a private Gmail) is not for their
  # teammates: members#index sends hide_private for a non-admin caller.
  attribute(:billing_email) { |user| params&.dig(:hide_private) ? nil : user.billing_email }
  attribute(:pending_billing_email) { |user| params&.dig(:hide_private) ? nil : user.pending_billing_email }

  # Always the resolved shape, never the raw NULL — the client renders a working
  # day either way, and "unset" is an implementation detail of the column.
  attribute :working_hours do |user|
    user.effective_working_hours
  end

  attribute :out_of_office do |user|
    user.out_of_office?
  end

  # avatar_url is stored as an internal storage key (set via the upload endpoint);
  # expose the signed streaming endpoint that serves it (nil when unset). An
  # already-absolute URL (legacy/external) is passed through untouched. The URL
  # carries a signed, expiring capability token (see AvatarToken) so it is not
  # enumerable by usr_ key; params[:avatar_org_key] records the org context.
  attribute :avatar_url do |user|
    next nil if user.avatar_url.blank?

    user.avatar_url.start_with?("http") ? user.avatar_url : UserSerializer.avatar_url(user, org_key: params&.dig(:avatar_org_key))
  end

  def self.avatar_url(user, org_key: nil)
    base = ENV.fetch("API_PUBLIC_URL", "http://localhost:4000")
    "#{base}/api/v1/account/avatar/#{AvatarToken.generate(user, org_key: org_key)}"
  end
end
