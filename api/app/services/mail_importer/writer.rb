require "mail"

module MailImporter
  # Stores one source message in its owner's private history, quietly: none of
  # InboundMailProcessor's spam scoring, rules, triage, push, webhooks or
  # out-of-office replies, which would answer years-old mail.
  #
  # Each owner keeps their own copy (docs/plans/mail-import.md D9): a message
  # two colleagues both had is stored once per owner, and a re-run finds the
  # owner's copy and stores nothing. Threads by the source's thread id, then
  # In-Reply-To/References within the owner's copy; never by subject.
  class Writer
    def initialize(import)
      @import = import
      @organization = import.organization
      @domain = import.domain
      @sealing = E2ee.available? && E2ee.effective?(@domain) && @domain.current_e2ee_key.present?
    end

    # :imported or :duplicate.
    def write(raw, source_id:, thread_id:, status:, read:, sent:, labels: [])
      mail = Mail.new(raw)
      message_id = mail.message_id.present? ? "<#{mail.message_id}>" : synthetic_id(source_id)
      at = mail.date&.to_time || Time.current

      if (existing = find_existing(message_id))
        remember_thread(thread_id, existing.conversation)
        label(existing.conversation, labels)
        return :duplicate
      end

      Message.transaction do
        conversation = thread_for(thread_id, mail) || create_conversation(mail, status, read, at)
        message = build_message(mail, conversation, message_id, sent, at)
        sealer = seal!(message) if @sealing
        message.save!
        store_attachments(mail, message, sealer)
        settle(conversation, message, status, read, at)
        remember_thread(thread_id, conversation)
        label(conversation, labels)
      end
      :imported
    rescue ActiveRecord::RecordNotUnique
      :duplicate # a concurrent import of the same Message-ID won the insert
    end

    private

    # No Message-ID (rare): one derived from the source id, so a resumed run
    # finds it again instead of storing it twice.
    def synthetic_id(source_id) = "<import.#{@import.provider}.#{source_id}@inbox2.invalid>"

    def owned = @organization.messages.where(owner_membership_id: @import.owner_membership_id)

    def find_existing(message_id)
      owned.find_by(message_id_header: message_id) || ((h = E2ee.threading_hmac(message_id)) && owned.find_by(msgid_hmac: h))
    end

    def thread_for(thread_id, mail)
      mapped = @import.threads.find_by(source_thread_id: thread_id)&.conversation if thread_id
      return mapped if mapped

      refs = [mail.in_reply_to, mail.references].flatten.compact.map { |r| "<#{r}>" }.reverse
      refs.each do |ref|
        found = find_existing(ref)
        return found.conversation if found
      end
      nil
    end

    def create_conversation(mail, status, read, at)
      subject = text(mail.subject).presence || "(no subject)"
      conversation = @organization.conversations.create!(
        domain: @domain, private: true, owner_membership_id: @import.owner_membership_id,
        status: status, read: read, created_at: at, updated_at: at,
        subject: @sealing ? nil : subject,
        subject_hmac: E2ee.subject_threading_hmac(mail.subject),
        from_address: @sealing ? nil : Array(mail.from).first,
        to_address: @sealing ? nil : Array(mail.to).first
      )
      ConversationAccess.create!(conversation: conversation, membership_id: @import.owner_membership_id)
      conversation
    end

    def build_message(mail, conversation, message_id, sent, at)
      plain, html = bodies(mail)
      conversation.messages.build(
        organization: @organization,
        from_address: header(mail, :from) || Array(mail.from).first,
        to_address: header(mail, :to), cc_address: header(mail, :cc),
        subject: text(mail.subject),
        body_plain: plain, body_html: html,
        content_type: html ? "text/html" : "text/plain",
        message_id_header: message_id,
        in_reply_to: mail.in_reply_to && "<#{Array(mail.in_reply_to).last}>",
        references_header: mail.references && Array(mail.references).map { |r| "<#{r}>" }.join(" "),
        msgid_hmac: E2ee.threading_hmac(message_id),
        refs_hmac: refs_hmacs(mail),
        subject_hmac: E2ee.subject_threading_hmac(mail.subject),
        is_inbound: !sent, is_draft: false,
        created_at: at, updated_at: at
      )
    end

    # Sealed domain: the row is sealed under the domain key, as outbound rows
    # are. A received message also drops its plaintext addresses, the posture
    # sealed inbound has (the MX ships none); a sent one keeps them, as
    # outbound does.
    def seal!(message)
      sealer = OutboundMessageSealer.new(message, @domain)
      sealer.seal_row!
      message.assign_attributes(from_address: nil, to_address: nil, cc_address: nil) if message.is_inbound
      sealer
    end

    # Plain: uploaded as is. Sealed: each part encrypted under the message's
    # DEK with the MX's AAD suffixes (mta/internal/smtpd/sealer.go), so
    # clients open imported and delivered attachments alike.
    def store_attachments(mail, message, sealer)
      mail.attachments.each_with_index do |part, i|
        content = part.decoded
        filename = text(part.filename).presence || "unnamed"
        content_type = part.mime_type || "application/octet-stream"
        if sealer
          att_aad = "#{sealer.aad}|att:#{i}"
          content_nonce, content_ct = E2ee.aead_encrypt(sealer.dek, content, att_aad)
          name_nonce, name_ct = E2ee.aead_encrypt(sealer.dek, filename, "#{att_aad}|name")
          key = storage.upload(content_ct, filename: "att-#{i}", organization_key: @organization.key)
          Attachment.create!(message: message, organization: @organization, filename: nil, content_type: content_type,
                             sealed_filename: Base64.strict_encode64(name_ct),
                             filename_nonce: Base64.strict_encode64(name_nonce),
                             content_nonce: Base64.strict_encode64(content_nonce),
                             size_bytes: content.bytesize, storage_key: key)
        else
          key = storage.upload(content, filename: filename, content_type: content_type, organization_key: @organization.key)
          Attachment.create!(message: message, organization: @organization, filename: filename,
                             content_type: content_type, size_bytes: content.bytesize, storage_key: key)
        end
      end
    end

    # The thread's list row follows its newest message, at the source's date,
    # not the import's, and takes the source's folder and read state.
    def settle(conversation, message, status, read, at)
      attrs = {}
      newest = conversation.messages.maximum(:created_at)
      attrs[:updated_at] = newest
      if at >= newest && !@sealing
        attrs[:from_address] = Array(Mail::AddressList.new(message.from_address.to_s).addresses).first&.address
        snippet = SnippetBuilder.build(message.body_plain, message.body_html)
        attrs[:snippet] = snippet if snippet.present?
      end
      attrs[:status] = Conversation::STATUS_OPEN if status == Conversation::STATUS_OPEN
      attrs[:read] = false unless read
      conversation.update_columns(attrs.compact)
    rescue Mail::Field::ParseError
      conversation.update_columns(attrs.except(:from_address).compact)
    end

    # The owner's labels on the thread, made as their private labels on first use.
    def label(conversation, names)
      names.uniq.each do |name|
        if Tag::RESERVED_NAMES.include?(name.downcase) || team_names.include?(name.downcase)
          name = "#{name} (#{@import.provider == MailImport::TAKEOUT ? "Gmail" : OauthProvider.label(@import.provider)})"
        end
        tag = Tag.find_or_create_by!(organization: @organization, membership_id: @import.owner_membership_id, name: name.truncate(100))
        ConversationTag.find_or_create_by!(conversation: conversation, tag: tag)
      end
    rescue ActiveRecord::RecordNotUnique
      retry
    end

    def team_names = @team_names ||= Tag.org_wide.where(organization: @organization).pluck(:name).to_set(&:downcase)

    # Remembers which conversation a source thread became.
    def remember_thread(thread_id, conversation)
      return unless thread_id

      MailImportThread.find_or_create_by!(mail_import: @import, source_thread_id: thread_id) do |t|
        t.conversation = conversation
      end
    rescue ActiveRecord::RecordNotUnique
      nil
    end

    def bodies(mail)
      if mail.multipart?
        [mail.text_part&.decoded, mail.html_part&.decoded].map { |b| text(b) }
      elsif mail.mime_type == "text/html"
        [nil, text(mail.decoded)]
      else
        [text(mail.decoded), nil]
      end
    end

    def header(mail, name) = text(mail[name]&.decoded).presence

    def refs_hmacs(mail)
      refs = Array(mail.references).map { |r| "<#{r}>" }
      refs << "<#{Array(mail.in_reply_to).last}>" if mail.in_reply_to
      refs.filter_map { |r| E2ee.threading_hmac(r) }.uniq
    end

    # Postgres TEXT refuses NUL; force UTF-8 so a stray charset never fails the insert.
    def text(str)
      return nil if str.nil?

      s = str.to_s.dup.force_encoding(Encoding::UTF_8)
      s = s.scrub("") unless s.valid_encoding?
      s.delete("\u0000")
    end

    def storage = @storage ||= S3StorageService.new
  end
end
