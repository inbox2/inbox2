# Base for API resource serializers. Centralizes the E5 rule that the public
# `id` is the model's prefixed-nanoid `key`, never the internal numeric primary
# key. Subclasses just declare their own `attributes`/`attribute` blocks.
#
# Serializers whose `id` is not `key` (e.g. WebauthnCredential's external_id),
# or that expose no public id at all, should `include Alba::Resource` directly
# instead of inheriting from here.
class ApplicationSerializer
  include Alba::Resource

  attribute :id do |resource|
    resource.key
  end
end
