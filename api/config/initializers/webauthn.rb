WebAuthn.configure do |config|
  # WEBAUTHN_ORIGIN may list several web origins (mail.inbox2.com, disk.inbox2.com).
  origins = ENV.fetch("WEBAUTHN_ORIGIN", "http://localhost:4173").split(",").map(&:strip).reject(&:empty?)
  config.allowed_origins = origins
  config.rp_name = "Inbox2"
  # The RP ID must be the web app's host (or a parent of it) or the browser
  # refuses the ceremony — derive it from the origin rather than defaulting to
  # "localhost", which silently broke every passkey on prod. Prod sets the
  # parent (inbox2.com) so one passkey works on every *.inbox2.com host.
  config.rp_id = ENV["WEBAUTHN_RP_ID"].presence || URI(origins.first).host
end
