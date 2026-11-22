# Processes inbound mail from the NATS JetStream MAIL_INBOUND stream.
#
# Pipeline: blocklist/allowlist → Rspamd scoring → conversation threading →
# message creation → routing rules → ActionCable broadcast.
#
# Spec references: 3.1.3, 7.1.3, 11.1, 16.2.1
class InboundMailProcessor
  def initialize(payload)
    @payload = payload
    @headers = payload["headers"] || {}
    @envelope = payload["envelope"] || {}
    @body = payload["body"] || {}
    @attachments = payload["attachments"] || []
    @auth = payload["authentication"] || {}
    @spam_result = nil
    @junk_sender = false
    # E2EE sealed payload (docs/E2EE.md Phase D): ciphertext + threading HMACs
    # built by the MX. When present, the plaintext fields above are empty.
    @sealed = payload["sealed"] || {}
  end

  # Sealed mail: the MX encrypted content/sender at ingestion; this consumer
  # only moves ciphertext and threads by HMAC.
  def sealed?
    Message::SEALED_ENCRYPTION_SCHEMES.include?(@payload["encryption_scheme"]) && @sealed.present?
  end

  def process
    domain = extract_recipient_domain
    return unless domain
    # Mail to the ESP's bounce domain is a delivery report for an API send.
    return { report: Esp::BounceProcessor.new(@payload).process } if domain == Esp::BOUNCE_DOMAIN

    @domain_record = find_domain(domain)
    return unless @domain_record

    organization = @domain_record.organization

    # DSN bounces and ARF complaints are machine reports, not user mail — route
    # them to delivery tracking + suppression instead of threading a conversation.
    report = route_report(organization)
    return { report: report } if report

    # Idempotency. The inbound NATS consumer is at-least-once (max_deliver 5), and
    # `process_inbound_message` naks on ANY error — so if the message inserts but
    # a later step (rules, broadcast, mobile push, space classify) raises, the
    # redelivery would append a duplicate. Dedupe on the stable RFC 5322
    # Message-ID before creating anything.
    message_id = @headers["message_id"]
    # Private copies (imported history) don't count: the shared copy is what
    # this delivery makes. A redelivery's private copies hit the unique index.
    if message_id.present? && organization.messages.shared.exists?(message_id_header: message_id)
      Rails.logger.info("[InboundMailProcessor] Duplicate inbound #{message_id} — skipping")
      return { duplicate: true }
    end
    # Sealed rows carry no plaintext Message-ID; the deterministic msgid_hmac
    # collides across redeliveries exactly the same way.
    if sealed? && @sealed["msgid_hmac"].present? && organization.messages.shared.exists?(msgid_hmac: @sealed["msgid_hmac"])
      Rails.logger.info("[InboundMailProcessor] Duplicate sealed inbound (msgid_hmac) — skipping")
      return { duplicate: true }
    end

    # Retired-mailbox handling: when a user was offboarded from this domain, the
    # admin chose to either bounce mail to their old local_part (reject here) or
    # reroute it (accept, and grant the chosen member access once threaded below).
    # After the dedup so an at-least-once redelivery doesn't repeat the lookup.
    return { bounced: true } if reject_for_mailbox_alias?(organization)

    sender_address = extract_email_address(@headers["from"]) || @envelope["mail_from"]

    # Sealed mail has no plaintext sender here — blocklist/allowlist and spam
    # scoring already ran MX-inline in the ingestion window (docs/E2EE.md); the
    # MX ships only the spam verdict as metadata.
    unless sealed?
      # Check blocklist/allowlist (spec 11.1.4, 11.1.5)
      filter_result = check_mail_filters(organization, sender_address)
      return filter_result if filter_result == :rejected

      # Rspamd spam scoring (spec 11.1.2) — only for paid plans with spam_filter enabled
      run_spam_check(organization)
    end
    adopt_sealed_spam_verdict if sealed?

    # A reply into private history (docs/plans/mail-import.md D10): every
    # recipient with their own copy of the thread gets it there; the shared
    # copy is only for recipients without one.
    copies = private_copies(organization)
    deliver_private_copies(organization, copies)
    return { private_copies: copies.size } unless shared_copy_needed?(copies)

    conversation = find_or_create_conversation(organization)
    new_thread = conversation.previously_new_record?
    grant_reroute_access(conversation)
    recipient_access_grants(conversation, organization)
    message =
      begin
        create_message(organization, conversation)
      rescue ActiveRecord::RecordNotUnique
        # A concurrent delivery of the same Message-ID inserted between the
        # exists? check above and this insert; the partial unique index on
        # (organization_id, message_id_header) rejected the duplicate. The
        # exists? check handles the common case; this closes the race window
        # once more than one inbound subscriber runs.
        Rails.logger.info("[InboundMailProcessor] Duplicate inbound #{message_id} (unique index) — skipping")
        return { duplicate: true }
      end
    create_attachments(organization, message)
    # Meeting invite: parse a text/calendar REQUEST part so the client can show
    # an Accept/Tentative/Decline banner. Sealed rows keep no server-side
    # plaintext, so invites can't be parsed there — the client would have to.
    parse_and_store_invite(message) unless sealed?
    # A sealed conversation keeps no plaintext preview (subject/snippet/sender
    # stay null); the client renders from the decrypted header.
    update_conversation_preview(conversation, message) unless sealed?

    # A reply into a trashed/archived thread pulls it back into the inbox as
    # unread — the sender resumed it, so it must resurface (and the mobile alert
    # below is now legitimate rather than pointing at a hidden thread).
    revive_hidden_thread(conversation) unless new_thread

    # Apply spam status to conversation if scored above threshold. Runs AFTER
    # revival so a resurfaced thread whose new message scores as spam is re-filed.
    apply_spam_status(organization, conversation)

    # Jev triage (docs/Triage.md), async so model latency never blocks ingest:
    # every inbound plaintext message re-runs label + priority; a new thread also
    # gets a Space and a summary. Paid-plan only (spec: AI triage is a plan
    # feature, mirrors spam_filter at #apply_spam_status).
    # Sealed mail is never triaged here: the decoupled triage worker labels it
    # from the transient excerpt stream (docs/E2EE.md Phase E).
    will_triage = !sealed? && organization.ai_triage_enabled? && SpaceClassifier.enabled?
    ClassifySpaceJob.perform_later(conversation.id, new_thread) if will_triage
    # Lore ontology (docs/Ontology.md): headers on every plan, the grounded LLM
    # pass paid-only inside the miner. The display name lives only in the From
    # header, so it rides along. Sealed rows have no plaintext to mine.
    LoreMineJob.perform_later(conversation.id, LoreMiner.display_name(@headers["from"])) unless sealed?
    # The job owns a new thread's mobile push (see below).
    defer_push = will_triage && new_thread

    # Out-of-office auto-reply (docs/Calendar.md). Runs AFTER apply_spam_status so
    # a message already filed as spam is never answered, and after the row exists
    # so a redelivery is deduped upstream rather than sending twice. Sealed mail
    # has no plaintext sender server-side, so there is nobody to answer.
    maybe_auto_reply(organization, message) unless sealed?

    # Run routing rules (spec 7.1.3)
    RuleExecutor.new(organization).execute_for(conversation, message)

    # Broadcast for real-time UI
    broadcast_new_message(organization, conversation, message)

    # Visible mobile push (APNs/FCM) — MX mail lives here, so the alert can
    # carry sender/subject; see docs/Cloud-Push.md "Mobile push". A new thread
    # going through triage defers its push to ClassifySpaceJob, so the alert
    # lands after the thread is filed; everything else notifies inline.
    notify_mobile_devices(organization, conversation, message) unless defer_push

    # First real mail through the pipe confirms the domain is live — promote a
    # verified org to receiving_mail (DnsCheckJob deliberately never sets this).
    promote_receiving_mail(organization)

    { conversation: conversation, message: message }
  end

  private

  # Prepare inbound text for a Postgres TEXT column.
  #
  # NUL: Postgres TEXT rejects \x00; a stray one (e.g. binary leaking into a
  # text part) would fail the insert on every redelivery and drop the mail,
  # stranding an empty conversation.
  #
  # NFC: senders transmit either normalization form — a macOS-composed Arabic
  # "أ" or Vietnamese "ế" often arrives decomposed — and two byte-different
  # spellings of the same word don't match each other in search or in a
  # filename comparison. Normalize on the way in so stored text has one
  # spelling. Invalid UTF-8 (which unicode_normalize would raise on) is left
  # as-is; it can only reach us if the JSON hop from the MX failed to coerce it.
  def text_column(str)
    return nil if str.nil?
    clean = str.delete("\u0000")
    clean.valid_encoding? ? clean.unicode_normalize(:nfc) : clean
  rescue ArgumentError, Encoding::CompatibilityError
    clean
  end

  def route_report(organization)
    raw_b64 = @payload["raw_message_b64"]
    return nil if raw_b64.blank?

    InboundReportRouter.new(
      organization,
      Base64.decode64(raw_b64),
      content_type_hint: @headers["content_type"]
    ).route
  rescue => e
    Rails.logger.warn("[InboundMailProcessor] report routing failed: #{e.message}")
    nil
  end

  # Verified → receiving_mail once mail actually flows, on the recipient *domain*.
  # A `receiving_mail` domain is left alone by DnsCheckJob, so this transition is
  # one-way (until DNS breaks). `organization` arg kept for the call-site signature.
  def promote_receiving_mail(_organization)
    return unless @domain_record&.status == Domain::STATUS_VERIFIED

    @domain_record.update!(status: Domain::STATUS_RECEIVING_MAIL)
    Rails.logger.info("[InboundMailProcessor] Promoted domain #{@domain_record.key} to receiving_mail")
  rescue => e
    Rails.logger.warn("[InboundMailProcessor] receiving_mail promotion failed: #{e.message}")
  end

  def extract_recipient_domain
    rcpt = @envelope["rcpt_to"]
    return nil if rcpt.blank?

    addr = rcpt.is_a?(Array) ? rcpt.first : rcpt
    addr.to_s.split("@").last&.downcase&.strip
  end

  def find_domain(domain)
    record = Domain.find_by(name: domain)
    # Billing-locked domains don't accept mail (defensive — MX already rejects).
    record unless record&.locked?
  end

  # The full RCPT TO local-part (left of @), lowercased. Sibling of
  # extract_recipient_domain, which throws this half away.
  def extract_recipient_local_part
    rcpt = @envelope["rcpt_to"]
    return nil if rcpt.blank?

    addr = rcpt.is_a?(Array) ? rcpt.first : rcpt
    addr.to_s.split("@").first&.downcase&.strip
  end

  # The recipient's mailbox local-part, without a +tag (waseem+receipts → waseem).
  def recipient_base_local_part
    local = extract_recipient_local_part
    local && Mailbox.base_local_part(local)
  end

  # True when mail to this recipient should be rejected because its mailbox was
  # retired with a bounce disposition (or a reroute whose target was removed).
  # A reroute disposition stashes the target membership for grant_reroute_access.
  def reject_for_mailbox_alias?(organization)
    local = recipient_base_local_part
    return false if local.blank?

    ma = @domain_record.mailbox_aliases.find_by(local_part: local)
    return false unless ma

    if ma.bounce? || ma.target_membership_id.nil?
      Rails.logger.info("[InboundMailProcessor] Bounced mail to retired mailbox #{local}@#{@domain_record.name}")
      return true
    end

    @reroute_target_membership = ma.target_membership
    false
  end

  # Grant the reroute target ongoing access to the (org-wide) conversation.
  def grant_reroute_access(conversation)
    return unless @reroute_target_membership

    conversation.conversation_accesses.find_or_create_by!(membership: @reroute_target_membership)
  rescue => e
    Rails.logger.warn("[InboundMailProcessor] reroute access grant failed: #{e.message}")
  end

  # Check blocklist/allowlist before processing (spec 11.1.4, 11.1.5)
  def check_mail_filters(organization, sender_address)
    return nil if sender_address.blank?

    sender_domain = sender_address.split("@").last&.downcase

    # Check blocklist — reject if sender or domain is blocked
    blocked = organization.mail_filters
      .where(kind: MailFilter::KIND_BLOCKLIST)
      .exists?(["value = ? OR value = ?", sender_address.downcase, sender_domain])

    if blocked
      Rails.logger.info("[InboundMailProcessor] Blocked sender #{sender_address} (blocklist)")
      return :rejected
    end

    # Check allowlist — if sender is trusted, skip spam scoring
    @allowlisted = organization.mail_filters
      .where(kind: MailFilter::KIND_ALLOWLIST)
      .exists?(["value = ? OR value = ?", sender_address.downcase, sender_domain])

    # Junk senders (someone marked their mail as spam): deliver, but file it
    # straight into Spam. Bayes alone can't do this — it needs 50 learns per
    # class before BAYES_* fires, so on low volume every later mail from a
    # sender you junked would keep landing in the inbox.
    @junk_sender = !@allowlisted && organization.mail_filters
      .where(kind: MailFilter::KIND_JUNK)
      .exists?(["value = ? OR value = ?", sender_address.downcase, sender_domain])

    nil
  end

  # Score message via Rspamd HTTP API (spec 11.1.2)
  # Sealed rows arrive with the MX-inline Rspamd verdict as metadata; adopt it
  # so apply_spam_status routes identically to the plaintext path.
  def adopt_sealed_spam_verdict
    return if @sealed["spam_score"].blank?

    @spam_result = RspamdClient::CheckResult.new(
      score: @sealed["spam_score"].to_f,
      action: @sealed["spam_action"],
      symbols: Array(@sealed["spam_symbols"]),
      required_score: nil
    )
  end

  def run_spam_check(organization)
    return if @allowlisted

    # Plan enforcement: only paid plans have spam filtering (spec 13.1.4).
    # Uses the org's effective plan (per-org override → owner subscription → Free).
    return unless organization.effective_plan.spam_filter

    raw_message_b64 = @payload["raw_message_b64"]
    return if raw_message_b64.blank?

    raw_message = Base64.decode64(raw_message_b64)
    client = RspamdClient.new
    @spam_result = client.check(
      raw_message,
      client_ip: @envelope["client_ip"],
      from: @envelope["mail_from"],
      rcpt: @envelope.dig("rcpt_to", 0)
    )

    Rails.logger.info("[InboundMailProcessor] Rspamd score=#{@spam_result.score} action=#{@spam_result.action} symbols=#{@spam_result.symbols.size}")
  rescue => e
    Rails.logger.warn("[InboundMailProcessor] Rspamd check failed: #{e.message}")
  end

  # Apply spam status based on Rspamd score + org threshold (spec 11.1.2), or
  # on the org having junked this sender before (no score needed — and no plan
  # gate either: filing your own junk isn't the paid Rspamd feature).
  def apply_spam_status(organization, conversation)
    if @junk_sender
      conversation.update!(status: Conversation::STATUS_SPAM)
      Rails.logger.info("[InboundMailProcessor] Filed conversation #{conversation.key} as spam (junk sender)")
      return
    end

    return unless @spam_result

    threshold = organization.effective_spam_threshold

    if @spam_result.spam?(threshold)
      conversation.update!(status: Conversation::STATUS_SPAM)
      Rails.logger.info("[InboundMailProcessor] Marked conversation #{conversation.key} as spam (score=#{@spam_result.score}, threshold=#{threshold})")
    end
  end

  # Resurface a trashed/archived thread when a new message threads into it:
  # back to the inbox (open) and marked unread. Spam threads are left as-is
  # (STATUS_SPAM is not in REVIVABLE_STATUSES) — apply_spam_status owns those.
  def revive_hidden_thread(conversation)
    # A personal Lore tick is the same "done": new mail brings the thread back for that member too.
    LoreMemberDone.where(conversation_id: conversation.id).delete_all
    return unless Conversation::REVIVABLE_STATUSES.include?(conversation.status)

    conversation.update!(status: Conversation::STATUS_OPEN, read: false)
    Rails.logger.info("[InboundMailProcessor] Revived #{conversation.key} to inbox on new message")
  end

  # { owner membership id => their private conversation } for each envelope
  # recipient on this domain whose own copy holds a message this one answers.
  # Sealed mail matches by HMAC; plaintext rows carry the HMAC too.
  def private_copies(organization)
    refs, column =
      if sealed? then [Array(@sealed["refs_hmac"]), :msgid_hmac]
      else [([@headers["in_reply_to"]] + @headers["references"].to_s.split(/\s+/)).map { |r| r.to_s.strip }.reject(&:blank?), :message_id_header]
      end
    owners = recipient_mailboxes.map(&:membership_id)
    return {} if refs.empty? || owners.empty?

    organization.messages.where(owner_membership_id: owners, column => refs).includes(:conversation)
      .order(created_at: :desc).each_with_object({}) { |m, out| out[m.owner_membership_id] ||= m.conversation }
  end

  # The mailboxes on this domain the envelope names.
  def recipient_mailboxes
    @recipient_mailboxes ||= begin
      host = @domain_record.name.downcase
      locals = Array(@envelope["rcpt_to"]).filter_map do |a|
        local, h = a.to_s.downcase.strip.split("@", 2)
        Mailbox.base_local_part(local) if h == host
      end
      @domain_record.mailboxes.where(local_part: locals).to_a
    end
  end

  # True unless every envelope recipient on the domain is the owner of a copy
  # (an alias or a mailbox without a copy still gets the shared thread).
  def shared_copy_needed?(copies)
    return true if copies.empty?

    covered = recipient_mailboxes.select { |mb| copies.key?(mb.membership_id) }.map { |mb| mb.local_part.downcase }
    Array(@envelope["rcpt_to"]).any? { |a| !covered.include?(Mailbox.base_local_part(a.to_s.downcase.strip.split("@", 2).first)) }
  end

  # The same message appended to each private copy, as its owner's row. No
  # rules, triage or auto-reply (those belong to the shared copy); the owner
  # is told the way any new mail tells them.
  def deliver_private_copies(organization, copies)
    copies.each_value do |conversation|
      message = create_message(organization, conversation)
      create_attachments(organization, message)
      update_conversation_preview(conversation, message) unless sealed?
      revive_hidden_thread(conversation)
      apply_spam_status(organization, conversation)
      broadcast_new_message(organization, conversation, message)
      notify_mobile_devices(organization, conversation, message)
    rescue ActiveRecord::RecordNotUnique
      next # a redelivery: this copy already has it
    end
  end

  def find_or_create_conversation(organization)
    return find_or_create_conversation_sealed(organization) if sealed?

    # Step 1: In-Reply-To match (most reliable)
    in_reply_to = @headers["in_reply_to"]
    if in_reply_to.present?
      existing = organization.messages.shared.find_by(message_id_header: in_reply_to)
      return existing.conversation if existing && joinable?(existing.conversation, organization)
      # Mixed-mode: the parent may be a SEALED row, findable only by HMAC.
      if (h = E2ee.threading_hmac(in_reply_to))
        existing = organization.messages.shared.find_by(msgid_hmac: h)
        return existing.conversation if existing && joinable?(existing.conversation, organization)
      end
    end

    # Step 2: References match (walk newest to oldest)
    references = @headers["references"]
    if references.present?
      ref_ids = references.split(/\s+/).reverse
      ref_ids.each do |ref_id|
        existing = organization.messages.shared.find_by(message_id_header: ref_id.strip)
        return existing.conversation if existing && joinable?(existing.conversation, organization)
        if (h = E2ee.threading_hmac(ref_id.strip))
          existing = organization.messages.shared.find_by(msgid_hmac: h)
          return existing.conversation if existing && joinable?(existing.conversation, organization)
        end
      end
    end

    # Step 3: Subject-based fallback with safeguards
    subject = @headers["subject"]
    if subject.present?
      normalized = normalize_subject(subject)
      if normalized.length >= 5
        # Never into imported private history: a subject match is a guess,
        # and it would hand shared mail to one person's archive. Only between
        # the same two correspondents, either direction: a sender mailing the
        # same subject to several people (Linear invites, 2026-10-24) merged
        # one member's personal mail into another's thread.
        from = extract_email_address(@headers["from"]).to_s.downcase
        rcpt = (@envelope["rcpt_to"]&.first || extract_email_address(@headers["to"])).to_s.downcase
        candidate = organization.conversations.not_private
          .where("subject = ? OR subject = ?", subject, normalized)
          .where("(LOWER(from_address) = :from AND LOWER(to_address) = :rcpt) OR " \
                 "(LOWER(from_address) = :rcpt AND LOWER(to_address) = :from)", from: from, rcpt: rcpt)
          .where("created_at > ?", 30.days.ago)
          .order(updated_at: :desc)
          .first
        return candidate if candidate && joinable?(candidate, organization)
        # Mixed-mode: a sealed thread exposes only subject_hmac. Plaintext
        # threads carry one too, so this is limited to sealed threads (no
        # stored addresses to check) on the recipient's domain — where every
        # member already sees sealed mail (Conversation.visible_to).
        if (sh = E2ee.threading_hmac(normalized))
          candidate = organization.conversations.not_private
            .where(subject_hmac: sh, from_address: nil, to_address: nil, domain_id: @domain_record&.id,
                   personal_membership_id: personal_recipient_id(organization))
            .where("created_at > ?", 30.days.ago)
            .order(updated_at: :desc)
            .first
          return candidate if candidate && joinable?(candidate, organization)
        end
      end
    end

    # Step 4: Create new conversation
    from_address = extract_email_address(@headers["from"])
    to_address = @envelope["rcpt_to"]&.first || @headers["to"]

    organization.conversations.create!(
      domain: @domain_record,
      subject: subject.presence || "(no subject)",
      subject_hmac: E2ee.subject_threading_hmac(subject),
      from_address: from_address,
      to_address: to_address,
      personal_membership_id: personal_recipient_id(organization),
      status: determine_initial_status
    )
  end

  # Whether this mail may join a thread its headers point at.
  # - A personal thread takes it only when every recipient on the domain
  #   already sees that thread (its owner or a grant) and none is a shared
  #   address. Else joining would hand the thread's history to someone new.
  # - A shared thread never takes tagged mail (ali+receipts@ is private).
  # Mail that may not join starts its own thread.
  def joinable?(conversation, organization)
    owners = recipient_owner_ids(organization)
    if conversation.personal_membership_id.present?
      return false if owners.include?(nil)

      sees = [conversation.personal_membership_id] + conversation.conversation_accesses.pluck(:membership_id)
      (owners - sees).empty?
    else
      domain_recipient_locals.none? { |l| Mailbox.tag_of(l) }
    end
  end

  # Local parts of the envelope recipients on this domain, as sent (tags kept).
  def domain_recipient_locals
    @domain_recipient_locals ||= begin
      host = @domain_record.name.downcase
      Array(@envelope["rcpt_to"]).filter_map do |a|
        local, h = a.to_s.downcase.strip.split("@", 2)
        local if h == host && local.present?
      end
    end
  end

  # The owner of each recipient on this domain, nil for a shared address
  # (info@). Tags are dropped (personal_membership_id_for).
  def recipient_owner_ids(organization)
    @recipient_owner_ids ||= domain_recipient_locals.map do |l|
      organization.personal_membership_id_for("#{l}@#{@domain_record.name}")
    end
  end

  # Whose personal mail this delivery is. Only when every recipient on the
  # domain is someone's own address: the first such owner holds the thread and
  # the others get an access grant (recipient_access_grants). One shared
  # address in the envelope (info@) makes the thread the team's — the sender
  # wrote to the team. A sealed thread stores no address, so this stamp is what
  # keeps it out of teammates' pools.
  def personal_recipient_id(organization)
    return @personal_recipient_id if defined?(@personal_recipient_id)

    owners = recipient_owner_ids(organization)
    @personal_recipient_id = owners.empty? || owners.include?(nil) ? nil : owners.first
  end

  # Every other recipient who owns an address in this envelope sees a NEW
  # thread too: a grant, not a copy, so the message is stored once (ali@ +
  # waseem@ → Ali's thread, granted to Waseem). Only new threads: a joined
  # thread already has every recipient (joinable?), and a grant there would
  # show its earlier messages.
  def recipient_access_grants(conversation, organization)
    return unless conversation.previously_new_record?

    (recipient_owner_ids(organization).compact.uniq - [conversation.personal_membership_id]).each do |mid|
      conversation.conversation_accesses.find_or_create_by!(membership_id: mid)
    end
  end

  # HMAC-only threading for sealed mail (docs/E2EE.md Phase D). Same shape as
  # the plaintext steps, minus the fuzzy raw-subject comparison (exact
  # normalized-HMAC match only — a documented degradation). refs_hmac arrives
  # oldest→newest with In-Reply-To appended last, so the reverse walk checks
  # the direct parent first.
  def find_or_create_conversation_sealed(organization)
    Array(@sealed["refs_hmac"]).reverse_each do |ref_hmac|
      existing = organization.messages.shared.find_by(msgid_hmac: ref_hmac)
      return existing.conversation if existing && joinable?(existing.conversation, organization)
      # Mixed-mode: the parent may be a PLAINTEXT row that predates HMAC
      # backfill — its Message-ID column can still be matched via HMAC compute
      # only at write time, so nothing to do here (plaintext rows written since
      # Phase D carry msgid_hmac).
    end

    # Same rule as the plaintext fallback: sealed threads on the recipient's
    # domain only, never a plaintext thread that happens to share the subject.
    if (sh = @sealed["subject_hmac"]).present?
      candidate = organization.conversations.not_private
        .where(subject_hmac: sh, from_address: nil, to_address: nil, domain_id: @domain_record&.id,
               personal_membership_id: personal_recipient_id(organization))
        .where("created_at > ?", 30.days.ago)
        .order(updated_at: :desc)
        .first
      return candidate if candidate && joinable?(candidate, organization)
    end

    # Sealed conversations keep every plaintext preview column null; the
    # subject_hmac is the only threading handle.
    organization.conversations.create!(
      domain: @domain_record,
      subject: nil,
      subject_hmac: @sealed["subject_hmac"].presence,
      from_address: nil,
      to_address: nil,
      personal_membership_id: personal_recipient_id(organization),
      status: determine_initial_status
    )
  end

  def create_message(organization, conversation)
    return create_sealed_message(organization, conversation) if sealed?

    from_address = extract_email_address(@headers["from"])

    attrs = {
      organization: organization,
      from_address: from_address || @envelope["mail_from"],
      to_address: @headers["to"],
      cc_address: @headers["cc"].presence,
      # Postgres TEXT rejects NUL bytes; a stray \x00 (e.g. binary leaking into
      # a text part) would otherwise fail the insert on every redelivery and
      # drop the mail, stranding an empty conversation.
      subject: text_column(@headers["subject"]),
      body_plain: text_column(@body["plain"]),
      body_html: text_column(@body["html"]),
      content_type: @headers["content_type"].presence || "text/plain",
      message_id_header: @headers["message_id"],
      in_reply_to: @headers["in_reply_to"],
      references_header: @headers["references"],
      is_inbound: true,
      is_draft: false,
      # The headers as they arrived, so a mail client gets the message with
      # its own headers (docs/Mail-Clients.md).
      raw_headers: (MailClient::Mime.header_block(Base64.decode64(@payload["raw_message_b64"])) if @payload["raw_message_b64"].present?),
      # Threading HMACs are stored for PLAINTEXT rows too (docs/E2EE.md), so a
      # later sealed reply can find this thread by HMAC alone.
      msgid_hmac: E2ee.threading_hmac(@headers["message_id"]),
      refs_hmac: plaintext_refs_hmacs,
      subject_hmac: E2ee.subject_threading_hmac(@headers["subject"])
    }

    # Store spam score if available
    if @spam_result
      attrs[:spam_score] = @spam_result.score
      attrs[:spam_action] = @spam_result.action
      attrs[:spam_symbols] = @spam_result.symbols
    end

    conversation.messages.create!(attrs)
  end

  # The ciphertext row (docs/E2EE.md Phase D): every plaintext content/sender
  # column stays null; the MX-built blobs and HMACs are stored verbatim.
  def create_sealed_message(organization, conversation)
    conversation.messages.create!(
      organization: organization,
      encryption_scheme: @payload["encryption_scheme"],
      domain_key_version: @sealed["key_version"],
      seal_aad: @sealed["aad"].presence,
      sealed_dek: @sealed["sealed_dek"],
      body_nonce: @sealed["body_nonce"],
      body_ciphertext: @sealed["body_ciphertext"],
      header_nonce: @sealed["header_nonce"],
      header_ciphertext: @sealed["header_ciphertext"],
      msgid_hmac: @sealed["msgid_hmac"].presence,
      refs_hmac: Array(@sealed["refs_hmac"]),
      subject_hmac: @sealed["subject_hmac"].presence,
      is_inbound: true,
      is_draft: false,
      spam_score: @sealed["spam_score"],
      spam_action: @sealed["spam_action"].presence,
      spam_symbols: Array(@sealed["spam_symbols"])
    )
  end

  # References + In-Reply-To HMACs for a plaintext row, mirroring the MX's
  # sealed derivation (References order kept, In-Reply-To appended last, deduped).
  def plaintext_refs_hmacs
    refs = @headers["references"].to_s.split(/\s+/).map(&:strip).reject(&:blank?)
    refs << @headers["in_reply_to"].strip if @headers["in_reply_to"].present?
    refs.filter_map { |r| E2ee.threading_hmac(r) }.uniq
  end

  def create_attachments(organization, message)
    return create_sealed_attachments(organization, message) if sealed?

    # Extract attachment content from raw message for S3 upload
    attachment_contents = extract_attachment_contents

    @attachments.each_with_index do |att, idx|
      filename = text_column(att["filename"]) || "unnamed"
      content_type = att["content_type"] || "application/octet-stream"
      content = attachment_contents[idx]

      storage_key = nil
      if content.present?
        begin
          storage_key = s3_service.upload(
            content,
            filename: filename,
            content_type: content_type,
            organization_key: organization.key
          )
        rescue => e
          Rails.logger.warn("[InboundMailProcessor] S3 upload failed for #{filename}: #{e.message}")
        end
      end

      attachment = Attachment.create!(
        message: message,
        organization: organization,
        filename: filename,
        content_type: content_type,
        size_bytes: att["size_bytes"] || content&.bytesize || 0,
        storage_key: storage_key
      )

      # Extract text for search indexing
      if attachment.searchable? && content.present?
        text = content.dup.force_encoding("UTF-8") rescue nil
        attachment.update!(content_text: text) if text.present?
      end
    end
  end

  # Sealed attachment metadata rows (docs/E2EE.md): ciphertext already spooled
  # by the MX for direct Garage upload — the bytes may land moments after this
  # row exists, so readers tolerate a brief not-yet-uploaded 404. No plaintext
  # filename, no content_text, no search_vector.
  def create_sealed_attachments(organization, message)
    Array(@sealed["attachments"]).each do |att|
      Attachment.create!(
        message: message,
        organization: organization,
        filename: nil,
        sealed_filename: att["sealed_filename"],
        filename_nonce: att["filename_nonce"],
        content_nonce: att["content_nonce"],
        content_type: att["content_type"] || "application/octet-stream",
        size_bytes: att["size_bytes"] || 0,
        storage_key: att["object_key"]
      )
    end
  end

  def extract_attachment_contents
    raw_b64 = @payload["raw_message_b64"]
    return [] if raw_b64.blank? || @attachments.empty?

    begin
      raw = Base64.decode64(raw_b64)
      parts = extract_mime_attachments(raw)
      parts
    rescue => e
      Rails.logger.warn("[InboundMailProcessor] MIME extraction failed: #{e.message}")
      []
    end
  end

  # Answers mail addressed to someone who is away. Every "don't send" decision
  # lives in OutOfOfficeResponder — this only supplies the raw source, because
  # the loop guards (Auto-Submitted, Precedence, List-*) are not in the MX's
  # fixed nine-header set and must be read from the message itself.
  def maybe_auto_reply(organization, message)
    raw_b64 = @payload["raw_message_b64"]
    OutOfOfficeResponder.maybe_reply(
      organization: organization,
      domain: @domain_record,
      message: message,
      envelope: @envelope,
      raw_mime: raw_b64.present? ? Base64.decode64(raw_b64) : nil,
      recipient_local_part: recipient_base_local_part
    )
  rescue => e
    Rails.logger.warn("[InboundMailProcessor] auto-reply failed: #{e.message}")
  end

  # Detect + store an emailed meeting invite. Reads the raw MIME (a bare
  # `text/calendar` part with no Content-Disposition never becomes an attachment
  # row — it lands in body_plain — so the raw message is the reliable source),
  # parses the first VEVENT, and stores it on the message for the RSVP banner.
  def parse_and_store_invite(message)
    ics = extract_calendar_part
    return if ics.blank?

    event = IcsParser.new(ics).parse.first
    return if event.nil? || event[:uid].blank?

    # REQUEST is answerable and gets the RSVP banner. REPLY, CANCEL and COUNTER
    # are how invitations WE sent come back — they update the stored event rather
    # than the message (docs/Calendar.md).
    #
    # PUBLISH (and a bare VEVENT with no METHOD at all) is not asking for an
    # answer — an appointment confirmation, a booking, a ticket. It used to be
    # dropped, which left the client nothing to render; it is stored now so the
    # banner can offer "Add to calendar" instead of a pointless RSVP.
    case event[:method].to_s.upcase
    when "REQUEST", "PUBLISH", "" then store_invite(message, event)
    when "REPLY"   then InboundCalendarResponse.apply_reply(message.organization, message, event)
    when "CANCEL"  then InboundCalendarResponse.apply_cancel(message.organization, message, event)
    when "COUNTER" then CalendarProposal.apply_counter(message.organization, message, event)
    end
  rescue IcsParser::ParseError, ActiveRecord::RecordInvalid => e
    Rails.logger.warn("[InboundMailProcessor] invite handling failed: #{e.message}")
  end

  def store_invite(message, event)
    # A method-less VEVENT is treated as PUBLISH: RFC 5545 says METHOD is what makes
    # an iCalendar object a scheduling message, so without one there is nothing to
    # answer. `answerable` decides whether the client offers RSVP or "Add to calendar".
    method = event[:method].to_s.upcase.presence || Message::CALENDAR_METHOD_PUBLISH
    answerable = method == Message::CALENDAR_METHOD_REQUEST
    message.update!(
      calendar_invite: {
        method: method,
        uid: event[:uid],
        summary: event[:summary],
        description: event[:description],
        location: event[:location],
        start: event[:dtstart]&.iso8601,
        end: event[:dtend]&.iso8601,
        all_day: !!event[:all_day],
        # Carried so accepting a repeating invite lands the whole series on the
        # calendar rather than a single orphaned occurrence.
        rrule: event[:rrule],
        timezone: event[:timezone],
        organizer_email: event[:organizer_email],
        organizer_name: event[:organizer_name],
        attendees: Array(event[:attendees]).map { |a| { "email" => a[:email], "name" => a[:name] } },
        sequence: event[:sequence].to_i
      },
      # Only an invitation gets an RSVP slot; a confirmation has nothing to answer,
      # and a status on it would render as an unanswered invite.
      rsvp_status: answerable ? Message::RSVP_STATUSES.first : nil # needs_action
    )
  end

  # Pull the first text/calendar part out of the raw MIME (attachment OR inline).
  def extract_calendar_part
    raw_b64 = @payload["raw_message_b64"]
    return nil if raw_b64.blank?

    require "mail"
    mail = Mail.new(Base64.decode64(raw_b64))
    parts = mail.multipart? ? mail.all_parts : [mail]
    part = parts.find { |p| p.mime_type.to_s.casecmp("text/calendar").zero? }
    part&.decoded
  rescue => e
    Rails.logger.warn("[InboundMailProcessor] calendar part extract failed: #{e.message}")
    nil
  end

  def extract_mime_attachments(raw_message)
    require "mail"
    mail = Mail.new(raw_message)
    contents = []

    mail.attachments.each do |att|
      contents << att.decoded
    rescue => e
      Rails.logger.warn("[InboundMailProcessor] Attachment decode error: #{e.message}")
      contents << nil
    end

    contents
  end

  def s3_service
    @s3_service ||= S3StorageService.new
  rescue => e
    Rails.logger.warn("[InboundMailProcessor] S3 unavailable: #{e.message}")
    nil
  end

  # Refresh the conversation's denormalized list-row preview to this
  # just-appended message: both the sender (from_address) and the snippet should
  # track the thread's newest message. updated_at is already bumped by the
  # messages counter_cache touch, so without refreshing from_address the row
  # would show the newest timestamp + snippet but the thread-originator's name
  # (the sender is frozen at conversation creation otherwise). Mirrors the
  # offline (Rust core) threading fix. Subject is left as the thread title.
  def update_conversation_preview(conversation, message)
    attrs = { from_address: message.from_address }
    snippet = SnippetBuilder.build(message.body_plain, message.body_html)
    attrs[:snippet] = snippet if snippet.present?
    conversation.update!(attrs)
  end

  def determine_initial_status
    # If DMARC result is quarantine, mark as spam
    dmarc_result = @auth.dig("dmarc", "result")
    dmarc_policy = @auth.dig("dmarc", "policy")

    if dmarc_result == "fail" && dmarc_policy == "quarantine"
      Conversation::STATUS_SPAM
    else
      Conversation::STATUS_OPEN
    end
  end

  def normalize_subject(subject)
    SubjectNormalizer.normalize(subject)
  end

  def extract_email_address(header_value)
    return nil if header_value.blank?

    if header_value =~ /<([^>]+)>/
      $1
    else
      header_value.strip
    end
  end

  def broadcast_new_message(organization, conversation, message)
    ActionCable.server.broadcast(
      "organization_#{organization.key}",
      {
        type: "new_message",
        conversation_id: conversation.key,
        message_id: message.key
      }
    )
  rescue => e
    Rails.logger.warn("[InboundMailProcessor] Broadcast error: #{e.message}")
  end

  # Visible APNs/FCM alert to the active human members who may SEE this thread —
  # members granted its domain (or all-domains), plus anyone directly assigned/
  # granted access. A domain-scoped member is never alerted to another domain's
  # mail. Spam never alerts.
  def notify_mobile_devices(organization, conversation, message)
    # Sealed mail with the per-domain preview opt-in: the MX shipped a
    # plaintext {from, subject} for the alert (docs/E2EE.md — deliberate,
    # documented leak). Never stored on the row; used for the push spec only.
    preview = sealed? ? @sealed["notification_preview"] : nil

    MobilePushSender.notify_new_message(organization, conversation, message, sealed_preview: preview)
  end
end
