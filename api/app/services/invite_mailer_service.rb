# Composes + dispatches the teammate-invite email through Messy, mirroring
# WaitlistMailerService: on-brand HTML rendered from an in-repo ERB template
# (app/views/invite_mailer/invite.html.erb), sent raw via MessyClient#send_message,
# fire-and-forget off the request thread via MessyTriggerJob.
class InviteMailerService
  # One email per invite batch (a person invited to several domains at once gets
  # a single message listing every new mailbox). The accept link carries the
  # first membership's freshly minted invite token (Membership#mint_invite_token!)
  # — accept-invite activates ALL pending invites for that person.
  def self.send_invite(email:, inviter:, invites:)
    token = invites.first&.invite_token
    raise ArgumentError, "invite has no minted token — call mint_invite_token! first" if token.blank?

    domains = invites.filter_map { |m| m.mailboxes.first&.domain&.name }
    subject = "You've been invited to #{domains.first || 'inbox2'}"
    body = render(
      "invite",
      inviter: inviter,
      addresses: invites.flat_map(&:email_addresses),
      accept_url: accept_url(token)
    )
    MessyTriggerJob.perform_later("send_message", to: email, subject: subject, body: body)
  end

  def self.render(template, **locals)
    ApplicationController.renderer.render(
      template: "invite_mailer/#{template}",
      formats: [:html],
      layout: false,
      locals: locals
    )
  end
  private_class_method :render

  def self.accept_url(invite_token)
    base = ENV.fetch("WEB_APP_URL", "https://app.inbox2.com").chomp("/")
    "#{base}/accept-invite?invite=#{invite_token}"
  end
  private_class_method :accept_url
end
