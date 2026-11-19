class MessageSerializer < ::ApplicationSerializer
  attributes :from_address, :to_address, :cc_address, :bcc_address, :subject,
             :body_plain, :body_html, :content_type,
             :is_inbound, :is_draft, :created_at, :scheduled_at

  attribute :message_id do |msg|
    msg.message_id_header
  end

  # Files on the message. Inbound MX mail has created these rows since the MX
  # receiver shipped (InboundMailProcessor#create_attachments uploads the parts to
  # S3), and AttachmentsController can hand back a presigned URL — but nothing
  # ever put them in a message payload, so every attachment on every MX message
  # was invisible in every client. Callers must preload (`includes(messages:
  # :attachments)`) or this is an N+1 per message.
  many :attachments, serializer: AttachmentSerializer

  # Meeting invite (docs/Meeting-Invites.md): the parsed VEVENT + the user's RSVP
  # state, so the client renders an Accept/Tentative/Decline banner. Null on
  # messages that aren't invites. A meeting read out of a body with no ICS
  # (`detected_meeting`) is served in the same shape as a PUBLISH, `detected: true`.
  attribute :invite do |msg|
    next MeetingDetector.as_invite(msg) if msg.calendar_invite.blank? && msg.detected_meeting.present?
    next nil if msg.calendar_invite.blank?

    msg.calendar_invite.merge("rsvp_status" => msg.rsvp_status)
  end

  # Meet-link meeting request (docs/Calendar.md): the banner payload for the
  # Accept/Decline request banner, status included. Null on ordinary messages.
  attribute :meeting_request do |msg|
    msg.meeting_request.presence
  end

  # Open tracking (docs/Open-Tracking.md). `tracked` = a pixel was embedded at
  # send. `open_stats` summarizes real (non-proxy) opens for the row indicator;
  # `opens` is the full who/when/where history for the reading pane. Both null on
  # untracked messages so the client shows nothing.
  attribute :tracked do |msg|
    msg.tracked?
  end

  attribute :open_stats do |msg|
    next nil unless msg.tracked?

    opens = msg.opens.to_a
    real = opens.reject(&:proxied)
    {
      opened: real.any?,
      open_count: real.size,
      last_opened_at: real.map(&:opened_at).max,
      proxy_hits: opens.size - real.size
    }
  end

  attribute :opens do |msg|
    next nil unless msg.tracked?

    msg.opens.map { |o| MessageOpenSerializer.new(o).to_h }
  end

  # Link tracking (docs/Open-Tracking.md): the rewritten links + their click
  # history for the reading pane. Null on messages with no tracked links. Only
  # tracked outbound messages carry a tracking_token, so untracked mail runs no
  # query here.
  attribute :link_stats do |msg|
    next nil if msg.tracking_token.blank?

    links = msg.tracked_links.to_a
    next nil if links.empty?

    clicks = links.flat_map { |l| l.clicks.to_a }
    real = clicks.reject(&:proxied)
    {
      click_count: real.size,
      links_clicked: links.count { |l| l.clicks.any? { |c| !c.proxied } },
      total_links: links.size,
      last_clicked_at: real.map(&:clicked_at).max,
      bot_hits: clicks.size - real.size
    }
  end

  attribute :links do |msg|
    next nil if msg.tracking_token.blank?

    links = msg.tracked_links.to_a
    next nil if links.empty?

    links.map { |l| TrackedLinkSerializer.new(l).to_h }
  end

  # The thread this message belongs to — lets a native client thread a reply or
  # attach uploads to a freshly-created draft's conversation.
  attribute :conversation_id do |msg|
    msg.conversation&.key
  end

  # E2EE (docs/E2EE.md Phase F). `none` rows keep the plaintext columns above;
  # sealed rows serve them as null plus this opaque blob bundle for
  # client-side decryption. `aad` is served verbatim — the exact bytes bound
  # into the ciphertexts at seal time.
  attribute :encryption_scheme do |msg|
    msg.encryption_scheme
  end

  attribute :sealed do |msg|
    next nil unless msg.sealed?

    {
      domain_key_version: msg.domain_key_version,
      aad: msg.seal_aad,
      sealed_dek: msg.sealed_dek,
      body_nonce: msg.body_nonce,
      body_ciphertext: msg.body_ciphertext,
      header_nonce: msg.header_nonce,
      header_ciphertext: msg.header_ciphertext,
      # Only on v2, so a v1 bundle stays byte-identical for the local mirror.
      scheme: (msg.encryption_scheme if msg.encryption_scheme == Message::ENCRYPTION_SCHEME_SEALED_BOX_V2)
    }.compact
  end
end
