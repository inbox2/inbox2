# Triages an inbound MX (in-domain) conversation with Jev (docs/Triage.md):
# an action label + a priority on every inbound message, and a Space while the
# thread has none. MX-only: local-channel mail is triaged in the Rust core.
#
# The questions are rebuilt from the org's *current* labels and classifiable
# spaces every run, so settings edits change routing immediately.
#
# Anything Jev can't place (no_match, low probability, a rejected key or
# request, throttled, or no provider configured) falls back to the org's holding
# pen (the Triage space). A transient Jev failure raises Jev::Client::TransientError
# so the caller can retry.
#
# New threads also get a one-line summary and the Lore to-do title from one
# OpenAI call (Llm::Client) — Jev can't write text.
class SpaceClassifier
  SUMMARY_PROMPT = <<~PROMPT.strip.freeze
    You summarize a single email for an inbox list. Reply with JSON only:
    {"summary": "...", "title": "..."}
    "summary": ONE line of at most 10 words: what the email is about and what it wants.
    Never repeat the subject line back, and never mention the sender's name.
    "title": the recipient's to-do as an imperative of 3-8 words in English, naming
    the counterpart and the thing, never the subject copied. Examples: "Pay Schiphol
    Privium membership invoice", "Reply to Chadi on the approval request", "Review the
    ADCB September statement", "Sign the KVK contract amendment". When nothing is
    asked, name what it is ("Read the Stripe product update").
  PROMPT
  SUMMARY_FORMAT = { type: "json_object" }.freeze

  # Where a reply's quoted history starts: "On <date>, <name> wrote:" (possibly
  # wrapped over two lines) or an Outlook "-----Original Message-----" divider.
  QUOTE_START = /^(?:On\s.{0,300}?wrote:[ \t]*$|-{2,}\s*Original Message\s*-{2,}|\*?From:\*?\s[^\n]*\n\*?(?:Sent|Date):)/im

  def initialize(organization, provider: ClassificationProviders.default, llm: Llm::Client.default,
                 breaker: TriageBreaker::Null.new)
    @organization = organization
    @provider = provider
    @llm = llm
    @breaker = breaker
  end

  # Cheap gate the ingest path checks before enqueuing triage work.
  def self.enabled?
    ClassificationProviders.default.configured?
  end

  # Plaintext lane: the newest inbound message is the one message Jev judges.
  # `new_thread` also writes the OpenAI summary. `retriage` (LoreRetriageJob)
  # writes the triage fields only: no summary, no meeting detection, no auto mode.
  def classify(conversation, message, new_thread: true, retriage: false)
    raw_to = message&.to_address.presence || conversation.to_address
    state = JevTriage.state(
      owner: MailHeaderEncoding.bare_addresses(raw_to.to_s).first,
      subject: conversation.subject,
      messages: [{ direction: JevTriage::DIRECTION_RECEIVED,
                   from: message&.from_address.presence || conversation.from_address,
                   text: message_text(conversation, message) }]
    )
    verdict = triage(conversation, state, rule_label: otp_rule(conversation.subject, message&.body_plain,
                                                               message&.body_html, conversation.snippet),
                                          message: message, auto: !retriage)
    return conversation if retriage

    summarize(conversation, message) if new_thread && verdict
    detect_meeting(conversation, message)
    conversation
  end

  # Next-action columns (docs/Triage.md "Next-action fields") for `label` on the
  # newest inbound plaintext message. Sealed mail: none (no server plaintext).
  def next_action_attributes(conversation, message, label)
    return {} if message.nil? || message.sealed?

    NextActionExtractor.attributes(label: label, subject: conversation.subject,
                                   text: message_text(conversation, message),
                                   message_date: message.created_at&.utc&.to_date)
  end

  # Sealed lane: the excerpt arrives from the transient triage stream (the
  # server has no plaintext). No summary — a stored summary of sealed mail would
  # be plaintext content (docs/E2EE.md "Output rule"); label + priority are
  # low-information metadata.
  def classify_excerpt(conversation, subject:, from:, to:, excerpt:)
    state = JevTriage.state(
      owner: MailHeaderEncoding.bare_addresses(to.to_s).first,
      subject: subject,
      messages: [{ direction: JevTriage::DIRECTION_RECEIVED, from: from, text: excerpt }]
    )
    triage(conversation, state, rule_label: otp_rule(subject, excerpt, nil, nil))
    conversation
  end

  # For a thread whose triage gave up (retries exhausted): park it in the
  # holding pen so it isn't left unrouted.
  def file_in_holding_pen(conversation)
    return if conversation.space_id || @organization.spaces.classifiable.none?

    pen = holding_pen
    conversation.update!(space_id: pen.id) if pen
  end

  private

  # Deterministic rule before Jev (the Rust core's `detect_label` twin): a
  # sign-in CODE is a NOTIFICATION, so Jev isn't asked the label. A sign-in link
  # alone goes to Jev (newsletters looked like one, 2026-10-20).
  def otp_rule(subject, body_plain, body_html, snippet)
    return nil unless OtpDetector.detect(subject: subject, body_plain: body_plain, body_html: body_html, snippet: snippet)&.key?("code")

    TriageLabel::NOTIFICATION
  end

  # Writes label/priority/source (a rule's label, else Jev's) and the space
  # (while the thread has none). Returns the verdict, or nil when Jev wasn't
  # asked/answered.
  def triage(conversation, state, rule_label: nil, message: nil, auto: true)
    spaces = conversation.space_id ? [] : @organization.spaces.classifiable.ordered.to_a
    verdict = ask(conversation, state, spaces, ask_label: rule_label.nil?)

    attrs = {}
    if rule_label
      # Provenance as the Rust core writes it: `rule:otp+jev:<model>`.
      attrs.merge!({ triage_label: rule_label, triage_priority: verdict&.priority,
                     triage_source: [TriageLabel::SOURCE_RULE_OTP, verdict&.source].compact.join("+") }.compact)
    elsif verdict
      attrs.merge!({ triage_label: verdict.label, triage_priority: verdict.priority,
                     triage_source: verdict.source }.compact)
    end
    if spaces.any?
      chosen = spaces.find { |s| s.slug == verdict&.space } || holding_pen
      attrs[:space_id] = chosen.id if chosen
    end
    attrs.merge!(next_action_attributes(conversation, message, attrs[:triage_label] || conversation.triage_label))
    conversation.update!(attrs) if attrs.any?
    LoreAuto.apply(conversation) if auto && attrs[:triage_label]
    verdict
  end

  def ask(conversation, state, spaces, ask_label:)
    return nil unless @provider.configured?

    # Circuit breaker: only call Jev while under the org/domain/user caps.
    unless @breaker.allow?
      @breaker.record_throttled!
      Rails.logger.info("[Triage] Throttled by circuit breaker — org #{@organization.key}, conv #{conversation.key}")
      return nil
    end

    labels = ask_label ? TriageLabel.ensure_defaults(@organization) : []
    questions = JevTriage.questions(labels: labels, spaces: spaces, ask_label: ask_label)
    verdict = @provider.triage(state: state, questions: questions)
    @breaker.record_triaged!
    verdict
  rescue Jev::Client::AuthError, Jev::Client::RequestError => e
    # Retrying can't fix a bad key or a malformed request: holding pen, no label.
    Rails.logger.error("[Triage] #{e.message} — conv #{conversation.key} left unlabelled")
    nil
  end

  public

  # One OpenAI call → the one-line summary + the Lore to-do title. `title_only`
  # (the lore:titles backfill) keeps an existing summary. Sealed mail: never.
  def summarize(conversation, message, title_only: false)
    return unless @llm.configured?
    return if message&.sealed?

    raw = @llm.complete(system: SUMMARY_PROMPT, user: email_excerpt(conversation, message), max_tokens: 80,
                        response_format: SUMMARY_FORMAT)
    summary, title = self.class.parse_summary(raw)
    attrs = { next_action_title: title }.compact
    attrs[:ai_summary_short] = summary if summary && !(title_only && conversation.ai_summary_short)
    conversation.update!(attrs) if attrs.any?
  end

  # `[summary, title]` from the JSON reply, each clamped to one line (title to
  # the column's 80 chars); either may be nil. A non-JSON reply (an endpoint
  # ignoring response_format) is taken as the plain summary line, no title.
  def self.parse_summary(raw)
    data = begin
      JSON.parse(raw.to_s)
    rescue JSON::ParserError
      nil
    end
    return [one_line(raw), nil] unless data.is_a?(Hash)

    title = one_line(data["title"])&.delete_suffix(".")&.slice(0, Conversation::NEXT_ACTION_TITLE_MAX)&.strip.presence
    [one_line(data["summary"]), title]
  end

  def self.one_line(text) = text.is_a?(String) ? text.strip.lines.first.to_s.strip.presence : nil

  private

  # A booked meeting in a body with no ICS (docs/Meeting-Invites.md "Detected
  # meetings"). Every inbound message, not just new threads: a confirmation is
  # usually a reply. MeetingDetector's clock-time gate keeps most mail off OpenAI.
  def detect_meeting(conversation, message)
    return if message.nil? || message.calendar_invite.present?

    meeting = MeetingDetector.detect(@llm, subject: conversation.subject,
                                           text: message_text(conversation, message), sent_at: message.created_at)
    message.update!(detected_meeting: meeting) if meeting
  end

  def email_excerpt(conversation, message)
    <<~TEXT.strip
      Subject: #{conversation.subject}
      From: #{conversation.from_address}
      To: #{conversation.to_address}

      #{message_text(conversation, message).to_s[0, 1200]}
    TEXT
  end

  # The new text of a message: HTML stripped, quoted history cut off.
  # ponytail: line heuristics, not the clients' structural quote detection
  # (docs/Email-Body-Collapsing.md) — port that if Jev keeps judging old quotes.
  def message_text(conversation, message)
    text = message&.body_plain.presence || strip_html(message&.body_html) || conversation.snippet
    text.to_s.split(QUOTE_START, 2).first.to_s
        .lines.reject { |l| l.start_with?(">") }.join.strip
  end

  def strip_html(html)
    return nil if html.blank?

    html.gsub(%r{<blockquote\b.*?</blockquote>}im, " ").gsub(/<[^>]+>/, " ").gsub(/[ \t]+/, " ").strip.presence
  end

  def holding_pen
    @organization.spaces.find_by(slug: Space::HOLDING_PEN_SLUG) ||
      @organization.spaces.where(classify: false).ordered.first
  end
end
