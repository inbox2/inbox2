class WebauthnCredentialSerializer
  include Alba::Resource

  attributes :nickname, :created_at

  # external_id is the public credential identifier; the numeric id never leaks
  attribute :id do |credential|
    credential.external_id
  end
end
