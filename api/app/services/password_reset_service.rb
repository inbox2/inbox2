# Issues a password-reset token for a user and dispatches the reset email via
# Messy (the "password.reset" template). Used by both the public reset-request
# endpoint and the SaaS "initiate reset" action. Returns false (no mail)
# when the user has no billing_email to send to.
#
# NOTE: the "password.reset" template + its variables ({ name, reset_url, token })
# must exist on the Messy account the API key belongs to.
class PasswordResetService
  TEMPLATE = "password.reset".freeze

  def self.call(user)
    new(user).call
  end

  def initialize(user)
    @user = user
  end

  def call
    return false if @user.blank? || @user.billing_email.blank?

    token = @user.generate_reset_token!

    MessyTriggerJob.perform_later(
      "trigger",
      trigger: TEMPLATE,
      to: @user.billing_email,
      channel: "email",
      data: {
        name: @user.display_name.presence || @user.username,
        reset_url: reset_url(token),
        token: token
      }
    )
    true
  end

  private

  def reset_url(token)
    base = ENV.fetch("WEB_APP_URL", "https://app.inbox2.com").chomp("/")
    "#{base}/reset-password?token=#{token}"
  end
end
