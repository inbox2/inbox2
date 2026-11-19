class SamlConfig < ApplicationRecord
  key_prefix "saml"

  belongs_to :organization

  validates :idp_entity_id, presence: true
  validates :idp_sso_url, presence: true
  validates :idp_certificate, presence: true

  def saml_settings
    settings = OneLogin::RubySaml::Settings.new
    settings.idp_entity_id = idp_entity_id
    settings.idp_sso_service_url = idp_sso_url
    settings.idp_cert = idp_certificate
    settings.name_identifier_format = name_id_format
    settings.sp_entity_id = "inbox2://#{organization.default_domain&.name}"
    # The IdP form-POSTs the assertion straight to the API, which mints a login
    # ticket and bounces the browser to the web app's /sso/saml/callback.
    settings.assertion_consumer_service_url =
      "#{ENV.fetch('APP_URL', 'http://localhost:4000').chomp('/')}/api/v1/orgs/#{organization.key}/saml/consume"

    # Require the IdP to sign assertions and reject expired/unsolicited ones.
    # Without want_assertions_signed an attacker can substitute an unsigned
    # assertion into a signed response (XML signature wrapping). Audience is
    # validated against sp_entity_id above.
    settings.security[:want_assertions_signed] = true
    settings.security[:want_messages_signed]   = false
    settings.security[:digest_method]          = XMLSecurity::Document::SHA256
    settings.security[:signature_method]       = XMLSecurity::Document::RSA_SHA256
    settings
  end
end
