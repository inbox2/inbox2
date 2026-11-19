class SamlConfigSerializer < ::ApplicationSerializer
  attributes :idp_entity_id, :idp_sso_url, :enabled, :name_id_format, :created_at

  # Never expose idp_certificate
end
