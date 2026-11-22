# Fan-out entry point for mobile push (APNs/FCM): builds a platform-agnostic
# "spec" describing the push and enqueues one delivery job per registered
# device. Two kinds, mirroring docs/Cloud-Push.md:
#
# - channel_sync: silent wake-to-sync for local channels. Content-free by
#   design (Rails never sees channel mail) — the app syncs with its own token
#   and posts the real notification locally.
# - new_message: visible alert for MX-pool mail, which lives in Rails and so
#   can carry sender/subject + the conversation key for tap-to-open.
class MobilePushSender
  KIND_CHANNEL_SYNC = "channel_sync".freeze
  KIND_NEW_MESSAGE = "new_message".freeze
  KIND_META_EVENT = "meta_event".freeze
  KIND_REMOVE_NOTIFICATION = "remove_notification".freeze
  KIND_BADGE = "badge".freeze
  # ActivityKit push for the iOS "Mail" Live Activity (lock-screen card with
  # Archive / Read / Trash). Never a banner: iOS only starts or updates the card.
  KIND_LIVE_ACTIVITY = "live_activity".freeze
  # Silent: the user's zones or zone dismissals changed on another device
  # (docs/Calendar.md "Zones"). The app refetches; `dismissed` lets it clear
  # that occurrence's notification / Live Activity without waiting for it.
  KIND_ZONES_CHANGED = "zones_changed".freeze

  # Trailing-edge debounce window for badge refreshes. Reading a thread
  # auto-marks it read after a 5s dwell, so working through an inbox would
  # otherwise fire one push per device per thread to settle on a single number.
  # ponytail: one global window; make it a per-plan setting only if someone
  # actually needs a different lag.
  BADGE_DEBOUNCE = 15.seconds

  # Silent push carrying a Meta webhook-relay buffer key. The app wakes, fetches the
  # raw payload from the relay, verifies the HMAC locally, then normalizes. No content
  # is in the push itself. Mirrors MetaWebhookBroadcaster's ActionCable payload.
  def self.meta_event(user, event_key:, object:)
    spec = {
      "kind" => KIND_META_EVENT,
      "data" => {
        "type" => KIND_META_EVENT,
        "event_key" => event_key,
        "object" => object
      },
      "alert" => nil,
      "collapse_id" => "meta-#{event_key}"
    }
    fan_out(user, spec)
  end

  # Mirrors ChannelPushBroadcaster's ActionCable payload as a silent push.
  def self.channel_sync(user, provider:, email:, history_id: nil)
    spec = {
      "kind" => KIND_CHANNEL_SYNC,
      "data" => {
        "type" => KIND_CHANNEL_SYNC,
        "provider" => provider,
        "email" => email,
        "history_id" => history_id
      }.compact,
      "alert" => nil,
      # One collapse slot per mailbox: a burst of change signals coalesces.
      "collapse_id" => "csync-#{Digest::SHA1.hexdigest("#{provider}:#{email}")[0, 20]}"
    }
    fan_out(user, spec)
  end

  def self.new_message(user, organization:, conversation:, message:, sealed_preview: nil)
    # Sealed mail (docs/E2EE.md Phase G): the push spec is a durable plaintext
    # surface twice over — it lands in solid_queue_jobs.arguments AND the
    # APNs/FCM payload. The server holds no plaintext for sealed rows, so by
    # default the spec is CONTENT-FREE: generic title, no body, IDs + sealed
    # flag + key version so a client notification extension can fetch +
    # decrypt + rebuild the rich alert on-device (follow-on).
    #
    # Per-domain toggle (`domains.e2ee_notification_preview`, default ON —
    # accepted risk): the MX ships a plaintext {from, subject} preview for the
    # alert — a deliberate, bounded leak of exactly those two fields for
    # lock-screen UX. Domains that turn it off get the content-free alert;
    # snippets/bodies never ride the push either way.
    if message.sealed?
      title = "New message"
      body = ""
      if sealed_preview.present?
        title = sealed_preview["from"].presence || title
        body = sealed_preview["subject"].to_s.truncate(180)
      end
      spec = {
        "kind" => KIND_NEW_MESSAGE,
        "data" => {
          "type" => KIND_NEW_MESSAGE,
          "organization_id" => organization.key,
          "conversation_id" => conversation.key,
          "message_id" => message.key,
          "sealed" => "true",
          "domain_key_version" => message.domain_key_version.to_s
        },
        "alert" => { "title" => title, "body" => body },
        "collapse_id" => message.key,
        "thread_id" => conversation.key
      }
      desktop_alert(user, organization, conversation, message, from: title, subject: body, snippet: "")
      fan_out(user, spec)
      return live_activity(user, content_state: live_activity_state(title, body, "", conversation, organization))
    end

    title = message.from_address
    body = [ conversation.subject.presence, conversation.snippet.presence ].compact.join(" — ")
    # A sign-in code or link (docs/Notifications.md): the app shows Copy / Open
    # link instead of Read. Sealed mail never gets here — the server can't read it.
    otp = OtpDetector.detect(subject: conversation.subject, body_plain: message.body_plain,
                             body_html: message.body_html, snippet: conversation.snippet)
    body = otp_lead(otp) + body if otp
    sender_host = message.from_address.to_s[/@([^\s>]+)/, 1]
    spec = {
      "kind" => KIND_NEW_MESSAGE,
      "data" => {
        "type" => KIND_NEW_MESSAGE,
        "organization_id" => organization.key,
        "conversation_id" => conversation.key,
        "message_id" => message.key,
        # Flat strings: FCM data values must be.
        "otp_code" => otp&.dig("code"),
        "otp_link" => otp&.dig("link"),
        # The site whose icon the card shows: the link's host, or for a code the
        # sender's domain (the push title is a display name, not an address).
        "otp_host" => otp && (otp["host"] || sender_host),
        # Every mail card shows the sender's site icon (docs/Notifications.md).
        "from_host" => sender_host
      }.compact,
      "alert" => { "title" => title, "body" => body.truncate(180) },
      "collapse_id" => message.key,
      "thread_id" => conversation.key
    }
    desktop_alert(user, organization, conversation, message,
                  from: title, subject: conversation.subject, snippet: conversation.snippet, otp: otp)
    fan_out(user, spec)
    live_activity(user, content_state: live_activity_state(title, conversation.subject.to_s, conversation.snippet.to_s, conversation, organization))
  end

  # The same alert, for the desktop/web clients over the user's own cable stream
  # (PushSyncChannel): they raise it through the notification path local-channel
  # mail already uses (docs/Notifications.md). Riding on new_message means it gets
  # this sender's audience, hidden-thread guard, sealed-preview rule and triage
  # deferral for free, and a meeting invite rides along so the card can answer
  # it. Not gated on the mobile push plan/config — that gate is
  # about APNs/FCM, and a desktop alert costs nothing.
  # What a sign-in alert leads with on a lock screen: the code itself, or where
  # the link goes.
  def self.otp_lead(otp)
    otp["code"] ? "Code #{otp["code"]} — " : "Sign-in link · #{otp["host"]} — "
  end
  private_class_method :otp_lead

  def self.desktop_alert(user, organization, conversation, message, from:, subject:, snippet:, otp: nil)
    ActionCable.server.broadcast(
      "push_sync_#{user.key}",
      {
        type: KIND_NEW_MESSAGE,
        organization_id: organization.key,
        workspace_slug: conversation.domain&.slug || organization.slug,
        conversation_id: conversation.key,
        message_id: message.key,
        from_address: from.to_s,
        subject: subject.to_s.truncate(180),
        snippet: snippet.to_s.truncate(180),
        updated_at: message.created_at&.iso8601,
        # The parsed invite, in MessageSerializer#invite's shape, so the card can
        # offer Accept/Decline (docs/Notifications.md). Never on sealed mail.
        invite: (message.calendar_invite.merge("rsvp_status" => message.rsvp_status) if message.calendar_invite.present? && !message.sealed?),
        otp: otp
      }.compact
    )
  rescue => e
    Rails.logger.warn("[MobilePushSender] desktop_alert error: #{e.message}")
  end
  private_class_method :desktop_alert

  # Keys mirror the app's MailActivityAttributes.ContentState (Codable) exactly.
  # `unread` is stamped per device by the delivery job (same number as the badge).
  def self.live_activity_state(sender, subject, snippet, conversation, organization)
    {
      "conversationKey" => conversation.key,
      "accountKey" => "",
      "orgId" => organization.key,
      "sender" => sender.to_s,
      "subject" => subject.to_s.truncate(120),
      "snippet" => snippet.to_s.truncate(180)
    }
  end

  # Start or update the Mail Live Activity on the user's iOS devices (or just
  # `devices`). The job picks the event per device: `update` to a running
  # activity's token, else `start` via the push-to-start token. Callers: MX
  # new_message (Rails knows the content) and the app itself via
  # push-devices/live-activity/start after a channel wake-sync (the app can't
  # start a card from the background, and Rails never sees channel mail).
  def self.live_activity(user, content_state:, devices: nil)
    return unless MobilePushConfig.apns_configured?
    return unless user&.push_enabled?

    devices ||= user.push_devices.where(platform: PushDevice::PLATFORM_IOS)
      .where("live_activity_start_token IS NOT NULL OR live_activity_token IS NOT NULL")
    spec = {
      "kind" => KIND_LIVE_ACTIVITY,
      "alert" => nil,
      "content_state" => { "conversationKey" => "", "accountKey" => "", "orgId" => "" }.merge(content_state)
    }
    fan_out(user, spec, devices: devices)
  end

  # Fan a visible new-message alert to every human who may see the thread.
  # HIDDEN THREADS NEVER ALERT: a conversation in an inbox-hidden status (spam,
  # trash, archived) is deliberately absent from every list, so a new message
  # threading into it must not ping the user with something they can't find.
  # Spam is Rspamd's verdict at ingest, so it is known before this runs. Called
  # inline from InboundMailProcessor, except for a new thread going through Jev
  # triage, whose alert ClassifySpaceJob sends once the thread is filed. The
  # status guard here is the last line of defence and mirrors INBOX_HIDDEN_STATUSES.
  def self.notify_new_message(organization, conversation, message, sealed_preview: nil)
    return if Conversation::INBOX_HIDDEN_STATUSES.include?(conversation.status)

    conversation_recipients(conversation).each do |user|
      new_message(user, organization: organization, conversation: conversation,
                        message: message, sealed_preview: sealed_preview)
    end
  rescue => e
    Rails.logger.warn("[MobilePushSender] notify_new_message error: #{e.message}")
  end

  def self.zones_changed(user, dismissed: nil)
    spec = {
      "kind" => KIND_ZONES_CHANGED,
      "data" => { "type" => KIND_ZONES_CHANGED, "dismissed" => dismissed }.compact,
      "alert" => nil,
      # A dismissal gets its own slot so it can't be coalesced away by a later
      # plain change; plain changes share one.
      "collapse_id" => dismissed ? "zdis-#{Digest::SHA1.hexdigest(dismissed)[0, 20]}" : "zones"
    }
    fan_out(user, spec)
  end

  # Silent push telling the app to clear any delivered notification(s) for a
  # conversation that has left the inbox (trashed/archived/spam/merged) — e.g.
  # the user dealt with it on another device, so the stale lockscreen banner
  # should go. MX-pool only: Rails owns these conversations and knows who was
  # alerted. Local-channel removals are reconciled client-side after a
  # channel_sync (the app re-syncs and drops notifications whose conversation
  # is gone), since Rails never sees channel mail.
  def self.remove_notification(user, conversation_key:)
    spec = {
      "kind" => KIND_REMOVE_NOTIFICATION,
      "data" => {
        "type" => KIND_REMOVE_NOTIFICATION,
        "conversation_id" => conversation_key
      },
      "alert" => nil,
      # Own collapse slot per conversation: removals coalesce, and never
      # collide with the original new_message (keyed on message key).
      "collapse_id" => "rm-#{conversation_key}"
    }
    fan_out(user, spec)
  end

  # App-icon badge refresh, no notification of any kind: another device changed
  # this user's MX unread (mark read/unread, spam, trash, archive, restore), so
  # the count on their other devices is stale. The push carries nothing — the
  # delivery job stamps the absolute badge on every APNs push, which is the
  # whole point of this one.
  #
  # It rides the ALERT lane, not the background lane. iOS throttles background
  # pushes hard (delivered late, coalesced, or dropped entirely when the app
  # isn't in use), which is exactly why marking spam on the desktop left the
  # iPhone badge stale until the app was next opened — the removal push that
  # carried the new count never arrived. A payload of only `aps.badge` shows no
  # banner and plays no sound; it just moves the number.
  #
  # Debounced on the TRAILING edge: the first change schedules one delivery
  # BADGE_DEBOUNCE from now and every change inside that window rides it, since
  # the delivery job reads the count when it runs, not when it's enqueued. So a
  # burst of triage costs one push per device carrying the settled number, and
  # the badge lags by at most the window. Leading-edge would be wrong here — it
  # would push the first count and swallow the rest, leaving the badge stale at
  # exactly the value the user has already moved past.
  def self.refresh_badge(user, devices: nil)
    return unless user
    # `unless_exist` write == "claim the window", and only the claimer enqueues.
    # A cache store that can't hold the key (test's :null_store) just means no
    # debounce, never a missed push.
    claimed = Rails.cache.write("mobile_push:badge:#{user.id}", true,
                                expires_in: BADGE_DEBOUNCE, unless_exist: true)
    return unless claimed

    fan_out(user, { "kind" => KIND_BADGE, "alert" => nil, "collapse_id" => "badge" },
            wait: BADGE_DEBOUNCE, devices: devices)
  end

  # Mirrors remove_for_org: any org member may hold the thread in their own
  # unread count, so all of them need the refreshed number. One joined query for
  # the whole org (instead of memberships→users→per-user device loads) — the
  # badge number itself is stamped per device by the delivery job, so only the
  # per-user debounce claim needs the user grouping.
  def self.refresh_badge_for_org(organization)
    PushDevice.joins(user: :memberships)
      .where(memberships: { organization_id: organization.id,
                            status: Membership::STATUS_ACTIVE,
                            member_type: Membership::TYPE_HUMAN })
      .distinct
      .includes(:user)
      .group_by(&:user)
      .each { |user, devices| refresh_badge(user, devices: devices) }
  end

  # Active human members of an org — the audience for org-wide removal pushes.
  def self.org_recipients(organization)
    organization.memberships
      .where(status: Membership::STATUS_ACTIVE, member_type: Membership::TYPE_HUMAN)
      .includes(:user)
      .map(&:user)
      .compact
      .uniq
  end

  # Active human members who may SEE a specific conversation — domain-scoped: an
  # all-domains member, a member granted the thread's domain, or anyone directly
  # assigned/access-granted to it. The right audience for a new-message alert.
  #
  # Asks Conversation.visible_to itself rather than re-deriving it: a copy here
  # once missed the personal-mailbox carve-out and alerted teammates with
  # the sender/subject of personal mail they can't open.
  # ponytail: one EXISTS per member per inbound message; batch it if org sizes grow.
  def self.conversation_recipients(conversation)
    thread = Conversation.where(id: conversation.id)
    conversation.organization.memberships
      .where(status: Membership::STATUS_ACTIVE, member_type: Membership::TYPE_HUMAN)
      .includes(:user)
      .select { |m| rings?(m, thread, conversation.domain) }
      .map(&:user).compact.uniq
  end

  # Visible to the member, and in a folder whose bell is on (AddressFolders:
  # Inbox on by default, every other folder off until the member turns it on).
  # A thread with no domain has no folders, so visibility alone decides.
  def self.rings?(membership, thread, domain)
    visible = thread.visible_to(membership)
    return false unless visible.exists?
    return true unless domain

    AddressFolders.new(membership, domain).notify_for?(visible)
  end

  # Fan a removal push to every org member for one or more conversation keys.
  def self.remove_for_org(organization, conversation_keys)
    keys = Array(conversation_keys).compact.uniq
    return if keys.empty?

    org_recipients(organization).each do |user|
      keys.each { |key| remove_notification(user, conversation_key: key) }
    end
  end

  # App-icon badge for an iOS device = the user's domain/MX unread (open + unread
  # across their active orgs, which Rails owns) + the device's last-reported
  # offline-channel unread (local SQLite, which Rails never sees). APNs badge is
  # absolute, so the delivery job stamps this on each iOS push; the app overrides
  # it with the exact live total whenever it runs.
  def self.badge_count(device)
    memberships = device.user.memberships
      .where(status: Membership::STATUS_ACTIVE)
      .includes(:organization)
    # Per membership, and through visible_to — the SAME scope
    # ConversationsController#unread_count serves the app. Counting the whole org
    # pool here instead meant a member without all-domains access saw a too-high
    # badge while the app was closed, which then dropped the moment they opened
    # it (the app recomputes from the endpoint and wins).
    # Only the Inbox counts (address folders): a shared address you do not show
    # in Inbox is a folder, and its mail does not raise the badge.
    mx_unread = memberships.sum do |membership|
      open = membership.organization.conversations
        .visible_to(membership)
        .where(status: Conversation::STATUS_OPEN, read: false)
      AddressFolders.across(membership, open, AddressFolders::INBOX).count
    end
    mx_unread + device.channel_unread.to_i
  end

  # `wait` delays delivery (badge debounce); everything else goes out at once.
  # `devices` skips the per-user load when the caller already batched them.
  def self.fan_out(user, spec, wait: nil, devices: nil)
    return unless MobilePushConfig.configured?
    return unless user&.push_enabled?

    job = wait ? MobilePushDeliveryJob.set(wait: wait) : MobilePushDeliveryJob
    (devices || user.push_devices.find_each).each do |device|
      job.perform_later(device.id, spec)
    end
  end
  private_class_method :fan_out
end
