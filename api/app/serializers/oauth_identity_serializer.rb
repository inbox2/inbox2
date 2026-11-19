class OauthIdentitySerializer
  include Alba::Resource

  attributes :provider, :email, :name

  attribute :connected_at do |identity|
    identity.created_at
  end

  # No public id — OauthIdentity is auth-internal and identified by provider
end
