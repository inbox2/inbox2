# Never exposes the token — provider + account label only.
class ConferencingConnectionSerializer < ::ApplicationSerializer
  attributes :provider, :account_email, :created_at
end
