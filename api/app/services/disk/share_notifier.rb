module Disk
  # Tells a member something was shared with them (spec F4): an in-app
  # notification and an email, both leading to the item in Disk. Sent when a
  # grant or a share membership is new, not when a role changes. The email goes
  # to the member's mailbox in this org, else their account email. Sealed items
  # are named generically: their names never reach the server.
  class ShareNotifier
    def self.granted(actor:, target:, node:, role:)
      what = node.sealed? ? "a sealed item" : "“#{node.name}”"
      deliver(actor, target, "shared #{what} with you", node, role)
    end

    def self.added_to_share(actor:, target:, share:, role:)
      deliver(actor, target, "added you to the “#{share.name}” share", share.root_node, role)
    end

    def self.deliver(actor, target, what, node, role)
      return if target.id == actor.id

      notify(target, kind: Notification::KIND_DISK_SHARED, title: "#{Disk.display_name(actor)} #{what}",
                     body: "You can #{role == Disk::ROLE_VIEW ? 'view' : 'edit'} it in Disk.",
                     path: Disk::WebPath.for(node, viewer: target), actor: actor)
    end
    private_class_method :deliver

    # An in-app notification and an email to one member, both leading to path
    # in the web app. Also used for quota warnings and plan changes.
    def self.notify(target, kind:, title:, body:, path:, actor: nil)
      Notification.create!(user: target.user, organization: target.organization, kind: kind,
                           title: title, body: body, url: path, actor_membership_id: actor&.id)

      to = target.primary_email_address || target.user.billing_email
      return if to.blank?

      url = Disk::WebPath.url(path)
      html = ApplicationController.renderer.render(template: "disk_mailer/shared", formats: [:html], layout: false,
                                                   locals: { title: title, body: body, url: url })
      MessyTriggerJob.perform_later("send_message", to: to, subject: title, body: html)
    end
  end
end
