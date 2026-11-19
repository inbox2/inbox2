# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc,
  # Second-factor / auth material: TOTP + WebAuthn codes and credentials. `:token`
  # already partial-matches access_token/refresh_token; these don't.
  :code, :totp_code, :credential,
  # A sealed Disk link's password verifier (docs/plans/disk-build.md 6.9).
  :verifier
]
