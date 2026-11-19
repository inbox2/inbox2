# Seals OUTBOUND mail for E2EE domains (docs/E2EE.md Phase I) — replies quote
# sealed inbound content, so the stored sent/draft copy and the queued MIME
# must be ciphertext too.
#
# Two seals, both performed in the request's RAM window (the documented
# transient widening — same trust class as the MX ingestion window):
#
#   seal_row!   — subject + bodies encrypted under the DOMAIN key (same
#                 sealed_box_v2 columns as inbound; members decrypt in their
#                 clients). From/to/cc stay plaintext: outbound recipients are
#                 wire metadata the server cannot deliver, bounce-process, or
#                 suppress without.
#   seal_mime!  — the composed RFC 5322 bytes encrypted to the MTA DELIVERY
#                 key, so the durable MAIL_OUTBOUND stream holds ciphertext
#                 only; the Go sender decrypts in RAM at delivery time.
class OutboundMessageSealer
  # The org domain that makes this outbound message sealable: the From address
  # belongs to an org domain that is effectively sealing (entitled + enabled +
  # keyed + not force-off).
  def self.sealing_domain(organization, from_address)
    return nil unless E2ee.available?

    host = MailHeaderEncoding.bare_addresses(from_address.to_s).first&.split("@")&.last&.downcase
    return nil if host.blank?

    domain = organization.domains.find_by(name: host)
    return nil unless domain && E2ee.effective?(domain) && domain.current_e2ee_key

    domain
  end

  # The message's DEK once seal_row! ran: an importer seals the attachments
  # under it, as the MX does for inbound (mta/internal/smtpd/sealer.go).
  attr_reader :dek, :aad

  def initialize(message, domain)
    @message = message
    @domain = domain
    @domain_key = domain.current_e2ee_key
  end

  # Encrypts the at-rest copy under the domain key and nulls the plaintext
  # content columns on the in-memory record (callers save afterwards, so
  # plaintext never reaches Postgres). Threading HMACs are kept so the thread
  # still groups.
  def seal_row!
    msgid_hmac = E2ee.threading_hmac(@message.message_id_header)
    aad = "#{@domain.id}|#{@domain_key.version}|#{msgid_hmac}"

    header = {
      subject: @message.subject,
      from: @message.from_address,
      to: @message.to_address,
      cc: @message.cc_address,
      bcc: @message.bcc_address,
      snippet: SnippetBuilder.build(@message.body_plain, @message.body_html),
      message_id: @message.message_id_header,
      in_reply_to: @message.in_reply_to
    }.compact.to_json
    body = { plain: @message.body_plain.to_s, html: @message.body_html.to_s }.to_json

    @aad = aad
    @dek = dek = E2ee.generate_dek
    header_nonce, header_ct = E2ee.aead_encrypt(dek, header, "#{aad}|header")
    body_nonce, body_ct = E2ee.aead_encrypt(dek, body, "#{aad}|body")
    sealed_dek = E2ee.seal_to_public_key(@domain_key.public_key, dek)

    @message.assign_attributes(
      encryption_scheme: Message::ENCRYPTION_SCHEME_SEALED_BOX_V2,
      domain_key_version: @domain_key.version,
      seal_aad: aad,
      sealed_dek: Base64.strict_encode64(sealed_dek),
      header_nonce: Base64.strict_encode64(header_nonce),
      header_ciphertext: Base64.strict_encode64(header_ct),
      body_nonce: Base64.strict_encode64(body_nonce),
      body_ciphertext: Base64.strict_encode64(body_ct),
      msgid_hmac: msgid_hmac,
      refs_hmac: refs_hmacs,
      subject_hmac: E2ee.subject_threading_hmac(@message.subject),
      subject: nil,
      body_plain: nil,
      body_html: nil
    )
    @message
  end

  # Encrypts the composed MIME to the MTA delivery key (AAD = the message's
  # public key, which rides the outbound payload) and stores the envelope on
  # the row for the deferred delivery job / retries.
  def seal_mime!(mime)
    public_key = E2ee.mta_delivery_public_key
    raise "INBOX2_MTA_DELIVERY_PUBLIC_KEY not configured — cannot seal outbound MIME" if public_key.blank?

    # The AAD is the message's public key, assigned before_create — force it
    # now for the unsaved record so seal + row agree.
    @message.send(:generate_key) if @message.key.blank?

    dek = E2ee.generate_dek
    nonce, ct = E2ee.aead_encrypt(dek, mime, @message.key.to_s)
    @message.sealed_mime = {
      v: 1,
      sealed_dek: Base64.strict_encode64(E2ee.seal_to_public_key(public_key, dek)),
      nonce: Base64.strict_encode64(nonce),
      ciphertext: Base64.strict_encode64(ct)
    }.to_json
    @message
  end

  private

  # References + In-Reply-To HMACs, mirroring the inbound derivation.
  def refs_hmacs
    refs = @message.references_header.to_s.split(/\s+/).map(&:strip).reject(&:blank?)
    refs << @message.in_reply_to.strip if @message.in_reply_to.present?
    refs.filter_map { |r| E2ee.threading_hmac(r) }.uniq
  end
end
