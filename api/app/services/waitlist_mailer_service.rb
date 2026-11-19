# Composes + dispatches the waitlist transactional emails through Messy. Both
# bodies are on-brand HTML rendered from in-repo ERB templates (app/views/
# waitlist_mailer/*) and sent raw via MessyClient#send_message — so the design
# lives in the repo; only the from-identity stays fixed on the Messy account.
# Sends are fire-and-forget off the request thread via MessyTriggerJob.
class WaitlistMailerService
  # Email Waseem (or WAITLIST_NOTIFY_EMAIL) that a new prospect just signed up.
  def self.notify_signup(signup)
    body = render("admin_notification", signup: signup)
    MessyTriggerJob.perform_later(
      "send_message",
      to: notify_email,
      subject: "New inbox2 waitlist signup — #{signup.name}",
      body: body
    )
  end

  # Email the prospect their single-use account-creation link.
  def self.send_invite(signup)
    body = render("invite", signup: signup, invite_url: invite_url(signup.invite_token))
    MessyTriggerJob.perform_later(
      "send_message",
      to: signup.email,
      subject: "You're in — create your inbox2 account",
      body: body
    )
  end

  def self.render(template, **locals)
    ApplicationController.renderer.render(
      template: "waitlist_mailer/#{template}",
      formats: [:html],
      layout: false,
      locals: locals
    )
  end
  private_class_method :render

  def self.notify_email
    ENV.fetch("WAITLIST_NOTIFY_EMAIL", "waseem@sadiq.nl")
  end
  private_class_method :notify_email

  # Public: the Pushleft Admin page shows the link once after an invite.
  def self.invite_url(token)
    base = ENV.fetch("WEB_APP_URL", "https://app.inbox2.com").chomp("/")
    "#{base}/signup?invite=#{token}"
  end
end
