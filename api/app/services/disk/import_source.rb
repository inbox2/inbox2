module Disk
  # The three import sources (docs/plans/disk-build.md 9b): their own app
  # registrations, read-only scopes per reach, and gate G7's fallback, which
  # offers a source only to allowlisted orgs until its app approval is recorded.
  #
  # Environment, per provider P in GOOGLE, MICROSOFT, DROPBOX:
  #   DISK_IMPORT_P_CLIENT_ID, DISK_IMPORT_P_CLIENT_SECRET   the importer's own app
  #   DISK_IMPORT_P_ORGS      comma-separated org keys or slugs offered the source
  #                           before approval ("*" for every org)
  #   DISK_IMPORT_P_APPROVED  "true" once the provider's approval is granted (G7)
  #   DISK_IMPORT_GOOGLE_SERVICE_ACCOUNT  a service account's JSON key with
  #                           domain-wide delegation, for an admin importing
  #                           members' My Drives (optional)
  #   DISK_IMPORT_P_<NAME>_URL  a provider endpoint, outside production only
  #                           (see .url): GOOGLE_{API,DIRECTORY,TOKEN,USERINFO,AUTHORIZE},
  #                           MICROSOFT_{GRAPH,LOGIN,TOKEN,AUTHORIZE},
  #                           DROPBOX_{API,CONTENT,TOKEN,AUTHORIZE}
  module ImportSource
    GOOGLE = OauthProvider::GOOGLE
    MICROSOFT = OauthProvider::MICROSOFT
    DROPBOX = OauthProvider::DROPBOX
    PROVIDERS = [GOOGLE, MICROSOFT, DROPBOX].freeze

    # Read-only, never the mail scopes. The org reach on Microsoft is
    # application permissions granted by tenant admin consent, so its "scope"
    # is .default and the permissions live on the app registration:
    # Files.Read.All, Sites.Read.All and User.Read.All (to match people).
    SCOPES = {
      GOOGLE => {
        Disk::ImportConnection::REACH_MEMBER => "https://www.googleapis.com/auth/drive.readonly email",
        Disk::ImportConnection::REACH_ORG => "https://www.googleapis.com/auth/drive.readonly email"
      },
      MICROSOFT => {
        Disk::ImportConnection::REACH_MEMBER => "Files.Read User.Read offline_access",
        Disk::ImportConnection::REACH_ORG => "https://graph.microsoft.com/.default"
      },
      DROPBOX => {
        Disk::ImportConnection::REACH_MEMBER => "account_info.read files.metadata.read files.content.read sharing.read",
        Disk::ImportConnection::REACH_ORG => "account_info.read files.metadata.read files.content.read sharing.read " \
                                             "team_data.member team_info.read members.read"
      }
    }.freeze

    # Delegated to the service account in the Workspace admin console. Mail
    # import adds gmail.readonly to the same delegation (MailImporter::Google).
    GOOGLE_DELEGATED_SCOPES = "https://www.googleapis.com/auth/drive.readonly " \
                              "https://www.googleapis.com/auth/admin.directory.user.readonly".freeze

    # The folder a personal drive lands in.
    FOLDER_NAMES = { GOOGLE => "Google Drive", MICROSOFT => "OneDrive", DROPBOX => "Dropbox" }.freeze

    module_function

    def known?(provider) = PROVIDERS.include?(provider.to_s)
    def env(provider, name) = ENV["DISK_IMPORT_#{provider.to_s.upcase}_#{name}"].presence
    def configured?(provider) = env(provider, "CLIENT_ID").present? && env(provider, "CLIENT_SECRET").present?

    # The importer's own app, with the consent and token endpoints its grants use.
    def client(provider)
      unless configured?(provider)
        raise Disk::Refused.new("The #{OauthProvider.label(provider)} importer is not configured on this server " \
                                "(DISK_IMPORT_#{provider.to_s.upcase}_CLIENT_ID and _CLIENT_SECRET)", status: 503)
      end

      { id: env(provider, "CLIENT_ID"), secret: env(provider, "CLIENT_SECRET"),
        authorize_url: url(provider, :authorize, OauthProvider.authorize_url(provider)),
        token_url: url(provider, :token, OauthProvider.token_url(provider)) }
    end

    OverrideRefused = Class.new(StandardError)

    # A provider endpoint: default, or DISK_IMPORT_P_<NAME>_URL so a test
    # harness can stand in a local fake provider. Refused outright in
    # production whatever else is set: an override there would send OAuth
    # codes, client secrets and tokens to another host.
    def url(provider, name, default)
      override = env(provider, "#{name.to_s.upcase}_URL") or return default
      if Rails.env.production?
        raise OverrideRefused, "DISK_IMPORT_#{provider.to_s.upcase}_#{name.to_s.upcase}_URL is set; " \
                               "importer endpoint overrides are refused in production"
      end

      override.chomp("/")
    end

    # Gate G7: offered to every org once approved, else to the allowlist.
    def allowed?(provider, organization)
      return true if env(provider, "APPROVED") == "true"

      list = env(provider, "ORGS").to_s.split(",").map(&:strip)
      list.include?("*") || list.include?(organization.key) || list.include?(organization.slug)
    end

    def offered?(provider, organization) = known?(provider) && configured?(provider) && allowed?(provider, organization)

    def scope(provider, reach) = SCOPES.fetch(provider).fetch(reach)

    def google_service_account
      raw = env(GOOGLE, "SERVICE_ACCOUNT")
      raw && JSON.parse(raw)
    end

    def adapter(provider) = "Disk::Importer::#{provider.to_s.camelize}".safe_constantize

    # Every address that names a member: their mailboxes and the emails of the
    # Google or Microsoft identities they sign in with. { email => membership }
    def member_index(organization)
      members = organization.memberships.where(status: Membership::STATUS_ACTIVE, member_type: Membership::TYPE_HUMAN)
        .includes(mailboxes: :domain, user: :oauth_identities)
      members.each_with_object({}) do |m, index|
        (m.email_addresses + m.user.oauth_identities.map(&:email)).compact.each { |e| index[e.downcase] ||= m }
      end
    end
  end
end
