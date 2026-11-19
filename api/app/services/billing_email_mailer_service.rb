# The confirmation link for a new contact address (docs/TODO.md 48.21). Raw HTML
# through Messy, fire-and-forget, as InviteMailerService does. Sent to the new
# address: clicking it is the proof that the address is theirs.
class BillingEmailMailerService
  def self.send_confirmation(user, address, token)
    base = ENV.fetch("WEB_APP_URL", "https://app.inbox2.com").chomp("/")
    body = ApplicationController.renderer.render(
      template: "billing_email_mailer/confirm", formats: [:html], layout: false,
      locals: { user: user, confirm_url: "#{base}/confirm-email?token=#{token}" }
    )
    MessyTriggerJob.perform_later("send_message", to: address, subject: "Confirm your email for inbox2", body: body)
  end
end
