# Accepts one API send: checks it, stores it, and queues one delivery per
# recipient. Raises Esp::Refused with the status to answer with.
class Esp::Send
  # Headers the caller may not set: we write them, or they would break the
  # message or its signature.
  RESERVED_HEADERS = %w[from to cc bcc subject date message-id mime-version return-path received
                        dkim-signature reply-to sender].freeze
  ALLOWANCE_LOCK = 0x45535041 # "ESPA"
  HEADER_NAME = /\A[A-Za-z0-9-]{1,64}\z/
  ADDRESS = /\A[^@\s<>,;]+@[a-z0-9.-]+\.[a-z0-9-]+\z/i

  def initialize(esp_key, params, idempotency_key: nil)
    @key = esp_key
    @org = esp_key.organization
    @p = params
    @idempotency_key = idempotency_key.presence
  end

  # => [Esp::Message, created?]
  def call
    if @idempotency_key && (existing = @org.esp_messages.find_by(idempotency_key: @idempotency_key))
      return replay(existing)
    end

    from = @p[:from].to_s.strip
    from_addrs = MailHeaderEncoding.bare_addresses(from)
    from_addr = from_addrs.first.to_s
    # The whole value becomes the From header, so it may name one sender only.
    refuse("from must be one address") unless from_addrs.size == 1 && from_addr.match?(ADDRESS)
    if (why = Esp::Domain.refusal_for(@org, from_addr.split("@").last.downcase))
      refuse(why, status: 403)
    end

    to, cc, bcc = %i[to cc bcc].map { |f| addresses(f) }
    recipients = (to + cc + bcc).map(&:downcase).uniq
    refuse("to must name at least one recipient") if to.empty?
    refuse("at most #{Esp::MAX_RECIPIENTS} recipients per send") if recipients.size > Esp::MAX_RECIPIENTS
    refuse("text or html is required") if @p[:text].blank? && @p[:html].blank?

    message = @org.esp_messages.new(
      esp_key: @key, from_address: from, to_address: to.join(", "), cc_address: cc.join(", ").presence,
      bcc_address: bcc.join(", ").presence, reply_to: @p[:reply_to].presence, subject: @p[:subject].to_s,
      tag: @p[:tag].presence, metadata: metadata, idempotency_key: @idempotency_key,
      message_id_header: "<#{SecureRandom.uuid}@#{from_addr.split('@').last.downcase}>"
    )
    message.raw_mime = Esp::Composer.new(message, text: @p[:text], html: @p[:html],
      headers: custom_headers, attachments: attachments).call
    message.size_bytes = message.raw_mime.bytesize
    refuse("message is larger than #{Esp::MAX_MESSAGE_BYTES / 1.megabyte} MB", status: 413) if message.size_bytes > Esp::MAX_MESSAGE_BYTES

    deliveries = Esp::Message.transaction do
      # One send at a time per organization: the allowance is checked and
      # spent under the same lock, so concurrent sends cannot both fit.
      Esp::Message.connection.execute("SELECT pg_advisory_xact_lock(#{ALLOWANCE_LOCK}, #{@org.id.to_i})")
      check_allowance!(recipients.size)
      message.save!
      recipients.map { |addr| message.deliveries.create!(organization: @org, recipient: addr) }
    end
    suppressed = @org.suppression_entries.where(address: recipients).pluck(:address).to_set
    deliveries.each do |delivery|
      if suppressed.include?(delivery.recipient)
        delivery.refuse_suppressed!
      else
        Esp::DeliverJob.perform_later(delivery.id)
      end
    end
    [message, true]
  rescue ActiveRecord::RecordNotUnique
    # Two requests raced on one idempotency key: the other one won.
    replay(@org.esp_messages.find_by!(idempotency_key: @idempotency_key))
  end

  private

  # The first request may have died between storing the send and queueing it.
  # Queue what never reached the mail queue; the job claims a delivery before
  # it publishes, so one that is already on its way is not sent twice.
  def replay(message)
    message.deliveries.where(status: Esp::Delivery::STATUS_QUEUED, published_at: nil)
      .pluck(:id).each { |id| Esp::DeliverJob.perform_later(id) }
    [message, false]
  end

  def refuse(message, status: 422) = raise(Esp::Refused.new(message, status: status))

  def addresses(field)
    list = Array(@p[field]).flat_map { |v| MailHeaderEncoding.bare_addresses(v.to_s) }.map(&:strip).reject(&:blank?)
    bad = list.reject { |a| a.match?(ADDRESS) }
    refuse("#{field} has an invalid address: #{bad.first}") if bad.any?
    list
  end

  def metadata
    raw = @p[:metadata]
    raw = raw.to_unsafe_h if raw.respond_to?(:to_unsafe_h)
    return {} if raw.blank?

    refuse("metadata must be a flat object of strings") unless raw.is_a?(Hash) && raw.size <= 20 &&
      raw.all? { |k, v| k.to_s.size <= 64 && (v.is_a?(String) || v.is_a?(Numeric)) && v.to_s.size <= 500 }
    raw.transform_values(&:to_s)
  end

  # Caller headers go into the message verbatim, so the name and value are
  # checked: a CR or LF in either would let the caller write further headers.
  def custom_headers
    raw = @p[:headers]
    raw = raw.to_unsafe_h if raw.respond_to?(:to_unsafe_h)
    return {} if raw.blank?

    refuse("headers must be an object") unless raw.is_a?(Hash)
    raw.each_with_object({}) do |(name, value), out|
      name = name.to_s
      value = value.to_s
      refuse("header #{name} is not allowed") if !name.match?(HEADER_NAME) || RESERVED_HEADERS.include?(name.downcase) ||
        name.downcase.start_with?("content-")
      refuse("header #{name} has an invalid value") if value.match?(/[\r\n\0]/) || value.size > 998
      out[name] = value
    end
  end

  def attachments
    Array(@p[:attachments]).map do |att|
      att = att.to_unsafe_h if att.respond_to?(:to_unsafe_h)
      filename = att["filename"].to_s
      refuse("each attachment needs a filename and base64 content") if filename.blank? || att["content"].blank?
      refuse("attachment filename is invalid") if filename.match?(%r{[\r\n\0/\\]})
      content = begin
        Base64.strict_decode64(att["content"].to_s.delete("\r\n"))
      rescue ArgumentError
        refuse("attachment #{filename} is not valid base64")
      end
      { filename: filename, content_type: att["content_type"].to_s.presence, content: content }
    end
  end

  def check_allowance!(count)
    limit = @org.effective_plan.esp_monthly_sends
    refuse("This plan does not include sending through the API", status: 403) if limit.zero?
    used = @org.esp_deliveries.where(created_at: Time.current.beginning_of_month..).count
    refuse("Monthly API sending allowance reached (#{limit})", status: 429) if used + count > limit
  end
end
