require "public_suffix"

# Mines one MX conversation into the domain's Lore ontology (docs/Ontology.md).
#
# Deterministic pass (every plan, headers only): an organization per
# registrable sender domain (freemail skipped), a person per address with
# works_at → that organization, a product for automated senders. LLM pass
# (paid, plaintext only, Llm::Client configured): projects, roles and
# relations from the latest inbound message, kept only when grounded
# (LoreFindings). Sealed rows keep no plaintext sender or body server-side, so
# both passes see nothing there; private (imported) threads are never mined —
# they belong to one person, not the team.
class LoreMiner
  # Local parts that mean "a system sent this" → a product/tool, not a person.
  AUTOMATED = /\A(?:no-?reply|do-?not-?reply|donotreply|notifications?|notify|alerts?|mailer(?:-daemon)?|
                 postmaster|bounces?|news(?:letter)?s?|updates?|digest|automated|system|robot|bot|
                 receipts?|billing|invoices?|support|info|hello|team|account|accounts|security)(?:[+._-].*)?\z/xi
  CORPORATE_SUFFIX = /\b(?:inc|ltd|llc|llp|plc|gmbh|bv|nv|sa|ag|ab|as|oy|corp|corporation|co|company|limited|
                       group|holding|holdings|fze|fzco|fzllc|pjsc|pvt|srl|sarl|spa)\b/x
  BODY_LIMIT = 8_000

  def self.display_name(header)
    name = header.to_s[/\A\s*"?([^"<]+?)"?\s*</, 1]&.strip
    name.presence unless name&.include?("@")
  end

  # Lowercase ASCII words, corporate suffixes dropped: "Acme Corp." → "acme".
  def self.normalize(name)
    name.to_s.unicode_normalize(:nfkd).encode("ASCII", invalid: :replace, undef: :replace, replace: "")
      .downcase.gsub(/[^a-z0-9]+/, " ").gsub(CORPORATE_SUFFIX, " ").squish
  end

  def self.registrable(host)
    PublicSuffix.domain(host, ignore_private: true)
  rescue PublicSuffix::Error
    nil
  end

  def initialize(conversation, llm: Llm::Client.default)
    @conversation = conversation
    @org = conversation.organization
    @domain = conversation.domain
    @llm = llm
  end

  def call(from_name: nil, use_llm: true)
    return unless minable?

    messages = @conversation.messages.where(is_draft: false).where.not(from_address: nil).order(:created_at).to_a
    messages.each_with_index do |m, i|
      deterministic(m, from_name: (i == messages.size - 1 ? from_name : nil))
    end
    extract(messages.reverse.find(&:is_inbound)) if use_llm && llm_allowed?
  end

  private

  def minable?
    # The ontology is org-wide: a member's personal mail stays out like imported history.
    @domain && !Conversation::DISCARDED_STATUSES.include?(@conversation.status) &&
      Conversation.org_readable.exists?(@conversation.id)
  end

  def llm_allowed?
    @org.ai_triage_enabled? && @llm.configured?
  end

  def own_hosts
    @own_hosts ||= @org.domains.pluck(:name).map(&:downcase)
  end

  def own?(host)
    own_hosts.any? { |d| host == d || host.end_with?(".#{d}") }
  end

  # Inbound: the sender. Outbound: the people we wrote to.
  def deterministic(message, from_name:)
    seen = message.created_at
    if message.is_inbound
      addr = message.from_address.to_s.strip.downcase
      sender(addr, from_name, automated: automated?(addr, message), at: seen, message: message)
    else
      [message.to_address, message.cc_address].flat_map { |h| MailHeaderEncoding.split_addresses(h) }.each do |mbox|
        addr = (mbox[/<([^>]+)>\s*\z/, 1] || mbox).strip.downcase
        sender(addr, self.class.display_name(mbox), automated: false, at: seen, message: message)
      end
    end
  end

  def automated?(addr, message)
    message.auto_submitted.present? && message.auto_submitted != "no" || addr.split("@").first.to_s.match?(AUTOMATED)
  end

  def sender(addr, display, automated:, at:, message:)
    local, _, host = addr.rpartition("@")
    return if local.empty? || host.empty? || own?(host)

    reg = self.class.registrable(host) or return
    freemail = BrandFetcher::FREEMAIL.include?(reg)
    label = reg.split(".").first
    if automated
      return if freemail

      product = entity(LoreEntity::KIND_PRODUCT, label.titleize, self.class.normalize(label), at, email_domain: reg)
      return mention(product)
    end

    person = entity(LoreEntity::KIND_PERSON, display || humanize(local), addr, at, address: addr,
                    email_domain: (reg unless freemail), better_name: display)
    mention(person)
    return if freemail

    org = entity(LoreEntity::KIND_ORGANIZATION, label.titleize, self.class.normalize(label), at, email_domain: reg)
    return unless org

    mention(org)
    fact(person, LoreFact::KIND_RELATION, LoreFact::RELATION_WORKS_AT, org.name, related: org, message: message,
                                                                                  confidence: 1.0)
  end

  def humanize(local)
    local.split(/[._-]+/).reject(&:empty?).map(&:capitalize).join(" ").presence || local
  end

  # Find-or-create by identity; widen first/last seen; upgrade a guessed name.
  def entity(kind, name, normalized, at, email_domain: nil, address: nil, better_name: nil)
    return nil if normalized.blank?

    e = LoreEntity.create_with(organization: @org, name: name.to_s.first(LoreFindings::MAX_NAME), email_domain: email_domain,
                               address: address, first_seen_at: at, last_seen_at: at)
                  .find_or_create_by!(domain: @domain, kind: kind, normalized_name: normalized)
    e = effective(e) or return nil
    attrs = {}
    attrs[:last_seen_at] = at if e.last_seen_at.nil? || at > e.last_seen_at
    attrs[:first_seen_at] = at if e.first_seen_at.nil? || at < e.first_seen_at
    attrs[:email_domain] = email_domain if e.email_domain.nil? && email_domain
    attrs[:name] = better_name if better_name.present? && !e.name_locked && e.name != better_name && !e.name.include?(" ")
    e.update_columns(attrs.merge(updated_at: Time.current)) if attrs.any?
    e
  rescue ActiveRecord::RecordNotUnique
    retry
  end

  def mention(entity)
    return unless entity

    res = LoreMention.insert_all([{ lore_entity_id: entity.id, conversation_id: @conversation.id, created_at: Time.current }],
                                 unique_by: %i[lore_entity_id conversation_id], returning: [:id])
    LoreEntity.increment_counter(:mention_count, entity.id) if res.rows.any?
  end

  # Upsert a fact. A repeat adds support (from another thread) and recomputes
  # confidence; a new mined fact below the floor is dropped, not stored.
  def fact(entity, kind, name, value, related: nil, quote: nil, message: nil, confidence: nil, grounding: 1.0)
    return unless entity

    fp = LoreFact.fingerprint(kind, name, value, related&.id)
    existing = LoreFact.find_by(lore_entity_id: entity.id, fingerprint: fp)
    if existing
      return if existing.removed_at || existing.conversation_id == @conversation.id

      support = existing.support + 1
      g = [existing.grounding, grounding].max
      c = confidence || LoreFindings.confidence(support, g)
      existing.update_columns(support: support, grounding: g, confidence: [c, existing.confidence].max)
      return
    end
    c = confidence || LoreFindings.confidence(1, grounding)
    return if c < LoreFindings::CONFIDENCE_FLOOR

    LoreFact.create!(entity: entity, kind: kind, name: name, value: value, related_entity: related, quote: quote,
                     conversation: @conversation, message: message, confidence: c, grounding: grounding,
                     fingerprint: fp, created_at: Time.current)
  rescue ActiveRecord::RecordNotUnique
    nil
  end

  def extract(message)
    return if message.nil? || message.sealed?
    return if message.body_plain.blank? && message.body_html.blank?

    body = message.body_plain.presence || ActionController::Base.helpers.strip_tags(message.body_html)
    raw = "From: #{message.from_address}\nSubject: #{message.subject}\n\n#{body}".first(BODY_LIMIT)
    text, = LoreFindings.defang(raw)
    system, user = LoreFindings.prompt(text)
    answer = @llm.complete(system: system, user: user, max_tokens: 2_000,
                           response_format: { type: "json_schema",
                                              json_schema: { name: "lore_findings", strict: true, schema: LoreFindings::SCHEMA } })
    grounded = LoreFindings.ground(LoreFindings.parse(answer), text)
    write(grounded, message)
  end

  def write(grounded, message)
    g = LoreFindings.grounding(grounded)
    # A finding seen once scores (1 - 0.5) * grounding: an answer that did not
    # ground in full is below the floor as a whole, entities included.
    return if LoreFindings.confidence(1, g) < LoreFindings::CONFIDENCE_FLOOR
    at = message.created_at
    by_name = {}
    resolve = lambda do |kind, name|
      by_name[[kind, name]] ||= resolve_entity(kind, name, at).tap { |e| mention(e) }
    end
    grounded[:entities].each do |e|
      ent = resolve.call(e[:kind], e[:name])
      e[:attributes].each do |a|
        fact(ent, LoreFact::KIND_ATTRIBUTE, a[:name], a[:value], quote: a[:quote], message: message, grounding: g)
      end
    end
    grounded[:relations].each do |r|
      from = resolve.call(r[:from][:kind], r[:from][:name])
      to = resolve.call(r[:to][:kind], r[:to][:name])
      next if from.nil? || to.nil? || from.id == to.id

      fact(from, LoreFact::KIND_RELATION, r[:label], to.name, related: to, quote: r[:quote], message: message, grounding: g)
    end
  end

  # A mined name onto an existing entity where one matches: a person by their
  # (display) name, anything else by normalized name.
  def resolve_entity(kind, name, at)
    if kind == LoreEntity::KIND_PERSON
      hit = LoreEntity.where(domain: @domain, kind: kind).where("LOWER(name) = ?", name.downcase).first
      return effective(hit) if hit
    end
    entity(kind, name, self.class.normalize(name), at)
  end

  # A hand edit stands: a merged row answers as its target, a removed one not at all.
  def effective(row)
    row = row.merged_into if row.merged_into_id
    row unless row&.removed_at
  end
end
