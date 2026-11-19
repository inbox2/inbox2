# The caller's own grant on a domain key: public key plus the secret sealed to them.
class DomainKeyGrantSerializer < ::ApplicationSerializer
  attribute(:id) { |grant| grant.key }
  attribute(:version) { |grant| grant.domain_key.version }
  attribute(:public_key) { |grant| grant.domain_key.public_key }
  attributes :sealed_secret_key
end
