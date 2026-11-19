# A mobile device's push token (APNs for iOS, FCM for Android), used to wake the
# app when new mail arrives — a silent sync nudge for local channels, a visible
# alert for MX-pool mail. The token is write-only through the API (E4): clients
# register/deregister by token, but it is never serialized back out.
class PushDevice < ApplicationRecord
  include HasPublicId
  key_prefix "pdev"

  PLATFORM_IOS = "ios".freeze
  PLATFORM_ANDROID = "android".freeze
  PLATFORMS = [ PLATFORM_IOS, PLATFORM_ANDROID ].freeze

  # APNs routes sandbox and production tokens through different gateways; debug
  # builds register as sandbox. FCM has a single environment (always production).
  ENV_SANDBOX = "sandbox".freeze
  ENV_PRODUCTION = "production".freeze
  ENVIRONMENTS = [ ENV_SANDBOX, ENV_PRODUCTION ].freeze

  belongs_to :user

  validates :token, presence: true, uniqueness: true
  validates :platform, inclusion: { in: PLATFORMS }
  validates :environment, inclusion: { in: ENVIRONMENTS }

  def ios?
    platform == PLATFORM_IOS
  end
end
