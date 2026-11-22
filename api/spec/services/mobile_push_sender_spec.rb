require "rails_helper"

RSpec.describe MobilePushSender do
  let(:user) { create(:user, username: "senderuser") }
  # Push is a paid feature (TODO 45.6) — give the user a paid org.
  let(:paid_org) { create(:organization, owner: user, domain: "senderteam.com") }
  let!(:paid_membership) { create(:membership, user: user, organization: paid_org, role: "owner", status: "active") }
  let!(:paid_subscription) { create(:subscription, organization: paid_org, plan: Plan.paid) }

  before do
    allow(MobilePushConfig).to receive(:configured?).and_return(true)
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear
  end

  describe ".channel_sync" do
    it "enqueues one delivery per device with a silent content-free spec" do
      ios = create(:push_device, user: user, platform: PushDevice::PLATFORM_IOS)
      android = create(:push_device, user: user, platform: PushDevice::PLATFORM_ANDROID)

      expect {
        described_class.channel_sync(user, provider: "gmail", email: "me@gmail.com", history_id: 42)
      }.to have_enqueued_job(MobilePushDeliveryJob).twice

      specs = enqueued_jobs_for(MobilePushDeliveryJob)
      expect(specs.map(&:first)).to match_array([ ios.id, android.id ])
      spec = specs.first.last
      expect(spec["kind"]).to eq("channel_sync")
      expect(spec["alert"]).to be_nil
      expect(spec["data"]).to eq("type" => "channel_sync", "provider" => "gmail",
        "email" => "me@gmail.com", "history_id" => 42)
      expect(spec["collapse_id"]).to start_with("csync-")
      expect(spec["collapse_id"].length).to be <= 64
    end
  end

  describe ".new_message" do
    it "enqueues a visible alert spec carrying the conversation key" do
      device = create(:push_device, user: user)
      org = create(:organization)
      conversation = create(:conversation, organization: org, subject: "Quarterly numbers", snippet: "Here are the figures")
      message = create(:message, organization: org, conversation: conversation, from_address: "cfo@corp.com")

      described_class.new_message(user, organization: org, conversation: conversation, message: message)

      id, spec = enqueued_jobs_for(MobilePushDeliveryJob).first
      expect(id).to eq(device.id)
      expect(spec["kind"]).to eq("new_message")
      expect(spec["alert"]["title"]).to eq("cfo@corp.com")
      expect(spec["alert"]["body"]).to include("Quarterly numbers")
      expect(spec["data"]).to include("conversation_id" => conversation.key,
        "organization_id" => org.key, "message_id" => message.key)
      expect(spec["thread_id"]).to eq(conversation.key)
    end

    it "broadcasts the same alert on the user's cable stream for desktop/web, without the mobile push gate" do
      allow(MobilePushConfig).to receive(:configured?).and_return(false)
      org = create(:organization)
      domain = create(:domain, organization: org, name: "acme-mail.test")
      conversation = create(:conversation, organization: org, domain: domain, subject: "Quarterly numbers", snippet: "Here are the figures")
      message = create(:message, organization: org, conversation: conversation, from_address: "cfo@corp.com")

      expect {
        described_class.new_message(user, organization: org, conversation: conversation, message: message)
      }.to have_broadcasted_to("push_sync_#{user.key}").with(hash_including(
        "type" => "new_message", "organization_id" => org.key, "workspace_slug" => "acme-mail-test",
        "conversation_id" => conversation.key, "message_id" => message.key,
        "from_address" => "cfo@corp.com", "subject" => "Quarterly numbers", "snippet" => "Here are the figures"
      ))
    end

    it "carries a meeting invite on the desktop alert so the card can answer it" do
      org = create(:organization)
      conversation = create(:conversation, organization: org)
      message = create(:message, organization: org, conversation: conversation, from_address: "boss@corp.com",
                                 calendar_invite: { "method" => "REQUEST", "summary" => "Sync", "start" => "2026-10-01T09:00:00Z" })

      expect {
        described_class.new_message(user, organization: org, conversation: conversation, message: message)
      }.to have_broadcasted_to("push_sync_#{user.key}").with(hash_including(
        "invite" => hash_including("method" => "REQUEST", "summary" => "Sync", "rsvp_status" => nil)
      ))
    end
  end

  describe ".new_message sign-in mail" do
    it "leads with the code and ships it to mobile and desktop" do
      org = create(:organization)
      conversation = create(:conversation, organization: org, subject: "Your login code", snippet: "Use it now")
      message = create(:message, organization: org, conversation: conversation, from_address: "noreply@app.test",
                                 body_plain: "Your verification code is 482910")

      expect {
        described_class.new_message(user, organization: org, conversation: conversation, message: message)
      }.to have_broadcasted_to("push_sync_#{user.key}").with(hash_including("otp" => { "code" => "482910" }))
    end

    it "names the sender's domain as the code's site" do
      create(:push_device, user: user)
      org = create(:organization)
      conversation = create(:conversation, organization: org, subject: "Your login code")
      message = create(:message, organization: org, conversation: conversation, from_address: "Husttle <noreply@husttle.com>",
                                 body_plain: "Your verification code is 482910")

      described_class.new_message(user, organization: org, conversation: conversation, message: message)

      _, spec = enqueued_jobs_for(MobilePushDeliveryJob).find { |_, s| s["kind"] == "new_message" }
      expect(spec["data"]).to include("otp_code" => "482910", "otp_host" => "husttle.com", "from_host" => "husttle.com")
      expect(spec["alert"]["body"]).to start_with("Code 482910 — ")
    end

    it "carries a sign-in link as flat data keys" do
      create(:push_device, user: user)
      org = create(:organization)
      conversation = create(:conversation, organization: org, subject: "Your login link for Messy")
      message = create(:message, organization: org, conversation: conversation, from_address: "devops@erip.me",
                                 body_plain: "Sign in: https://app.messy.sh/validate/abc")

      described_class.new_message(user, organization: org, conversation: conversation, message: message)

      _, spec = enqueued_jobs_for(MobilePushDeliveryJob).find { |_, s| s["kind"] == "new_message" }
      expect(spec["data"]).to include("otp_link" => "https://app.messy.sh/validate/abc", "otp_host" => "app.messy.sh")
      expect(spec["data"]).not_to have_key("otp_code")
      expect(spec["alert"]["body"]).to start_with("Sign-in link · app.messy.sh — ")
    end

    it "leaves ordinary mail alone" do
      create(:push_device, user: user)
      org = create(:organization)
      conversation = create(:conversation, organization: org, subject: "Lunch?")
      message = create(:message, organization: org, conversation: conversation, body_plain: "Room 4021 at noon")

      described_class.new_message(user, organization: org, conversation: conversation, message: message)

      _, spec = enqueued_jobs_for(MobilePushDeliveryJob).find { |_, s| s["kind"] == "new_message" }
      expect(spec["data"].keys.grep(/otp/)).to be_empty
    end
  end

  describe ".live_activity (ActivityKit push)" do
    before { allow(MobilePushConfig).to receive(:apns_configured?).and_return(true) }

    it "new_message also enqueues a live_activity spec for iOS devices holding an ActivityKit token" do
      with_token = create(:push_device, user: user, platform: PushDevice::PLATFORM_IOS, live_activity_start_token: "st")
      create(:push_device, user: user, platform: PushDevice::PLATFORM_IOS) # no token: alert only
      org = create(:organization)
      conversation = create(:conversation, organization: org, subject: "Quarterly numbers", snippet: "Here are the figures")
      message = create(:message, organization: org, conversation: conversation, from_address: "cfo@corp.com")

      described_class.new_message(user, organization: org, conversation: conversation, message: message)

      live = enqueued_jobs_for(MobilePushDeliveryJob).select { |_, spec| spec["kind"] == "live_activity" }
      expect(live.map(&:first)).to eq([ with_token.id ])
      state = live.first.last["content_state"]
      expect(state).to include("conversationKey" => conversation.key, "orgId" => org.key, "accountKey" => "",
                               "sender" => "cfo@corp.com", "subject" => "Quarterly numbers", "snippet" => "Here are the figures")
    end

    it "channel_sync never starts a card (Rails can't tell new mail from a write-back echo)" do
      create(:push_device, user: user, platform: PushDevice::PLATFORM_IOS, live_activity_start_token: "st")

      described_class.channel_sync(user, provider: "gmail", email: "me@gmail.com")

      kinds = enqueued_jobs_for(MobilePushDeliveryJob).map { |_, spec| spec["kind"] }
      expect(kinds).to eq([ "channel_sync" ])
    end

    it "targets only the given devices" do
      mine = create(:push_device, user: user, platform: PushDevice::PLATFORM_IOS, live_activity_start_token: "st")
      create(:push_device, user: user, platform: PushDevice::PLATFORM_IOS, live_activity_start_token: "st2")

      described_class.live_activity(user, content_state: { "conversationKey" => "c1" }, devices: [ mine ])

      expect(enqueued_jobs_for(MobilePushDeliveryJob).map(&:first)).to eq([ mine.id ])
    end
  end

  describe ".notify_new_message" do
    let(:org) { create(:organization, owner: user) }
    let(:conversation) { create(:conversation, organization: org, status: Conversation::STATUS_OPEN) }
    let(:message) { create(:message, organization: org, conversation: conversation, from_address: "a@b.com") }

    it "fans a visible alert out to the thread's recipients" do
      create(:push_device, user: user)
      allow(described_class).to receive(:conversation_recipients).with(conversation).and_return([ user ])
      expect { described_class.notify_new_message(org, conversation, message) }
        .to have_enqueued_job(MobilePushDeliveryJob)
    end

    # A new message threading into a hidden thread (spam/trash/archived) must not
    # alert: the thread is absent from every list, so the push would point the
    # user at something they can't find.
    Conversation::INBOX_HIDDEN_STATUSES.each do |hidden|
      it "never alerts for a #{hidden} conversation (recipients never resolved)" do
        create(:push_device, user: user)
        conversation.update!(status: hidden)
        expect(described_class).not_to receive(:conversation_recipients)
        expect { described_class.notify_new_message(org, conversation, message) }
          .not_to have_enqueued_job(MobilePushDeliveryJob)
      end
    end

    it "never alerts a restricted member to a teammate's personal thread (visible_to, not a copy of it)" do
      porg = create(:organization, domain: "pers.test", with_default_domain: true)
      dom = porg.default_domain
      restricted = create(:membership, organization: porg, user: create(:user), role: "member", status: "active")
      restricted.update!(all_domains: false, domains: [ dom ])
      owner = create(:membership, organization: porg, user: create(:user), role: "member", status: "active")
      owner.update!(all_domains: false, domains: [ dom ])
      owner.mailboxes.create!(domain: dom, local_part: "ann")
      personal = create(:conversation, organization: porg, domain: dom, to_address: "ann@pers.test")
      shared = create(:conversation, organization: porg, domain: dom, to_address: "info@pers.test")

      expect(described_class.conversation_recipients(personal)).not_to include(restricted.user)
      expect(described_class.conversation_recipients(personal)).to include(owner.user)
      # A shared address rings the people who can reply as it (in their Inbox
      # by default), never a read-only member (folder bells, AddressFolders).
      dom.update!(shared_addresses: [{ "local_part" => "info" }])
      owner.update!(send_as_addresses: ["info@pers.test"])
      expect(described_class.conversation_recipients(shared)).to include(owner.user)
      expect(described_class.conversation_recipients(shared)).not_to include(restricted.user)
    end

    it "swallows a push failure so the caller never breaks" do
      allow(described_class).to receive(:new_message).and_raise("fcm down")
      expect { described_class.notify_new_message(org, conversation, message) }.not_to raise_error
    end
  end

  describe ".remove_notification" do
    it "enqueues a silent removal spec carrying the conversation key" do
      device = create(:push_device, user: user)

      described_class.remove_notification(user, conversation_key: "conv_abc123")

      id, spec = enqueued_jobs_for(MobilePushDeliveryJob).first
      expect(id).to eq(device.id)
      expect(spec["kind"]).to eq("remove_notification")
      expect(spec["alert"]).to be_nil
      expect(spec["data"]).to eq("type" => "remove_notification", "conversation_id" => "conv_abc123")
      expect(spec["collapse_id"]).to eq("rm-conv_abc123")
    end
  end

  describe ".remove_for_org" do
    it "fans a removal push to every active human member for each key" do
      org = create(:organization)
      create(:subscription, organization: org, plan: Plan.paid) # push is paid (45.6)
      member = create(:user, username: "orgmember")
      create(:membership, organization: org, user: member,
        status: Membership::STATUS_ACTIVE, member_type: Membership::TYPE_HUMAN)
      create(:push_device, user: member)

      described_class.remove_for_org(org, [ "conv_one", "conv_two" ])

      specs = enqueued_jobs_for(MobilePushDeliveryJob).map(&:last)
      expect(specs.map { |s| s["data"]["conversation_id"] }).to match_array([ "conv_one", "conv_two" ])
      expect(specs).to all(include("kind" => "remove_notification"))
    end

    it "no-ops for an empty key list" do
      org = create(:organization)
      member = create(:user, username: "orgmember2")
      create(:membership, organization: org, user: member,
        status: Membership::STATUS_ACTIVE, member_type: Membership::TYPE_HUMAN)
      create(:push_device, user: member)

      expect {
        described_class.remove_for_org(org, [])
      }.not_to have_enqueued_job(MobilePushDeliveryJob)
    end
  end

  describe ".refresh_badge" do
    it "enqueues a content-free badge spec on one collapse slot" do
      device = create(:push_device, user: user)

      described_class.refresh_badge(user)

      id, spec = enqueued_jobs_for(MobilePushDeliveryJob).first
      expect(id).to eq(device.id)
      expect(spec["kind"]).to eq(described_class::KIND_BADGE)
      expect(spec["alert"]).to be_nil
      expect(spec["data"]).to be_nil
      expect(spec["collapse_id"]).to eq("badge")
    end

    # The test env runs :null_store, which can't hold the debounce claim — give
    # this one a real store so the window is actually exercised.
    context "with a working cache store" do
      include ActiveSupport::Testing::TimeHelpers
      before { allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new) }

      it "coalesces a burst into one delayed delivery per device" do
        create(:push_device, user: user)

        5.times { described_class.refresh_badge(user) }

        jobs = enqueued_jobs_for(MobilePushDeliveryJob)
        expect(jobs.length).to eq(1)
      end

      it "delays it so the count settles before the job reads it" do
        create(:push_device, user: user)

        expect {
          described_class.refresh_badge(user)
        }.to have_enqueued_job(MobilePushDeliveryJob).at(a_value > Time.current)
      end

      it "pushes again once the window has passed" do
        create(:push_device, user: user)

        described_class.refresh_badge(user)
        travel(described_class::BADGE_DEBOUNCE + 1.second) { described_class.refresh_badge(user) }

        expect(enqueued_jobs_for(MobilePushDeliveryJob).length).to eq(2)
      end
    end
  end

  describe ".refresh_badge_for_org" do
    it "fans one badge refresh to every active human member" do
      org = create(:organization)
      create(:subscription, organization: org, plan: Plan.paid)
      member = create(:user, username: "badgemember")
      create(:membership, organization: org, user: member,
        status: Membership::STATUS_ACTIVE, member_type: Membership::TYPE_HUMAN)
      create(:push_device, user: member)

      described_class.refresh_badge_for_org(org)

      specs = enqueued_jobs_for(MobilePushDeliveryJob).map(&:last)
      expect(specs.length).to eq(1)
      expect(specs.first["kind"]).to eq(described_class::KIND_BADGE)
    end
  end

  describe ".badge_count" do
    it "sums the user's domain (open+unread) mail and the device's reported channel unread" do
      org = create(:organization)
      create(:membership, organization: org, user: user,
        status: Membership::STATUS_ACTIVE, member_type: Membership::TYPE_HUMAN)
      create(:conversation, organization: org, status: Conversation::STATUS_OPEN, read: false)
      create(:conversation, organization: org, status: Conversation::STATUS_OPEN, read: false)
      create(:conversation, organization: org, status: Conversation::STATUS_OPEN, read: true)
      create(:conversation, organization: org, status: Conversation::STATUS_TRASH, read: false)
      device = create(:push_device, user: user, channel_unread: 5)

      expect(described_class.badge_count(device)).to eq(7) # 2 domain unread + 5 channel
    end

    it "counts only what the member may see, like the app's unread-count endpoint" do
      # A member scoped to one domain: the badge pushed while the app is closed
      # must not count the domains they can't open.
      org = create(:organization)
      mine = create(:domain, organization: org, name: "mine.example")
      theirs = create(:domain, organization: org, name: "theirs.example")
      membership = create(:membership, organization: org, user: user,
        status: Membership::STATUS_ACTIVE, member_type: Membership::TYPE_HUMAN,
        role: Membership::ROLE_MEMBER, all_domains: false)
      membership.domains = [mine]
      create(:conversation, organization: org, domain: mine,
        status: Conversation::STATUS_OPEN, read: false)
      create(:conversation, organization: org, domain: theirs,
        status: Conversation::STATUS_OPEN, read: false)
      device = create(:push_device, user: user, channel_unread: 0)

      expect(described_class.badge_count(device)).to eq(1)
    end
  end

  it "no-ops when mobile push is unconfigured" do
    allow(MobilePushConfig).to receive(:configured?).and_return(false)
    create(:push_device, user: user)

    expect {
      described_class.channel_sync(user, provider: "gmail", email: "a@b.c")
    }.not_to have_enqueued_job(MobilePushDeliveryJob)
  end

  it "no-ops when the user has push disabled" do
    allow(user).to receive(:push_enabled?).and_return(false)
    create(:push_device, user: user)

    expect {
      described_class.channel_sync(user, provider: "gmail", email: "a@b.c")
    }.not_to have_enqueued_job(MobilePushDeliveryJob)
  end

  it "no-ops for a user with no devices" do
    expect {
      described_class.channel_sync(user, provider: "gmail", email: "a@b.c")
    }.not_to have_enqueued_job(MobilePushDeliveryJob)
  end

  def enqueued_jobs_for(job_class)
    ActiveJob::Base.queue_adapter.enqueued_jobs
      .select { |j| j[:job] == job_class }
      .map { |j| ActiveJob::Arguments.deserialize(j[:args]) }
      .map { |args| [ args[0], args[1] ] }
  end
end
