# Capability token for streaming a user's avatar in a plain <img> tag.
#
# API auth is bearer-only (Authorization header), which an <img> request cannot
# send — so the avatar endpoint can't require a live session the way every other
# endpoint does. Instead the avatar URL carries a signed, expiring token that is
# minted ONLY while serializing a user to an authenticated caller (their own
# account, or a member of an org they share — see UserSerializer / the member
# list). That makes the endpoint non-enumerable: you can no longer fetch an
# arbitrary user's avatar by guessing usr_ keys, and the grant expires.
#
# Mirrors ListUnsubscribeService's signed-token mechanism.
class AvatarToken
  EXPIRY = 7.days

  # Sign "show the avatar for this user". `org_key` records the org context the
  # URL was issued in (a co-member list or the user's own account) so the
  # capability is scoped to that org and auditable.
  def self.generate(user, org_key: nil)
    verifier.generate({ "u" => user.key, "o" => org_key }, expires_in: EXPIRY)
  end

  # The user key a token authorizes, or nil if the token is forged/expired.
  def self.user_key(token)
    return nil if token.blank?

    verifier.verify(token)["u"]
  rescue ActiveSupport::MessageVerifier::InvalidSignature
    nil
  end

  def self.verifier
    Rails.application.message_verifier(:avatar)
  end
end
