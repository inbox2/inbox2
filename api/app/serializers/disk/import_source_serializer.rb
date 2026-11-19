module Disk
  # One import source as GET /imports/sources shows it: whether this member
  # (and, for owners and admins, the org) is connected and what it can see.
  class ImportSourceSerializer
    include Alba::Resource

    Source = Struct.new(:provider, :connection, :org_available, :org_connection, :spaces, :spaces_error,
                        keyword_init: true)

    attributes :provider, :org_available, :spaces_error

    attribute :label do |s|
      OauthProvider.label(s.provider)
    end

    attribute :folder_name do |s|
      Disk::ImportSource::FOLDER_NAMES[s.provider]
    end

    attribute :connected do |s|
      s.connection.present?
    end

    attribute :account_email do |s|
      s.connection&.account_email
    end

    attribute :org_connected do |s|
      s.org_connection.present?
    end

    attribute :org_account do |s|
      s.org_connection && (s.org_connection.account_email || s.org_connection.tenant)
    end

    # [{ id, kind, name, email, member_id }]: member_id is the org member a
    # source user's drive would land with, or null when nobody matches.
    attribute :spaces do |s|
      s.spaces&.map do |sp|
        { id: sp.id, kind: sp.kind, name: sp.name, email: sp.email, member_id: sp.member&.key }
      end
    end
  end
end
