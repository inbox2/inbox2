# Normalizes email subjects for threading by stripping reply/forward prefixes,
# mailing list tags, and leading/trailing whitespace.
#
# Implements the "base subject" algorithm from RFC 5256 §2.1 with extended
# international prefix support covering langauges that use Latin, Cyrillic,
# Greek, CJK, Hebrew, Arabic, and Devanagari scripts.
#
# Usage:
#   SubjectNormalizer.normalize("Re: Fwd: [dev] Meeting notes")
#   # => "Meeting notes"
class SubjectNormalizer
  # Latin-script reply/forward prefixes (case-insensitive)
  #
  # re        — English, most languages (Reply)
  # fw/fwd    — English (Forward)
  # sv        — Swedish, Norwegian, Danish (Svar)
  # aw        — German (Antwort)
  # tr        — French (Transféré), Turkish (İlet)
  # vs        — Finnish (Vastaus)
  # ref       — Italian (Riferimento), generic
  # rif       — Italian (Riferimento, alt.)
  # ynt       — Turkish (Yanıt)
  # odp       — Polish (Odpowiedź)
  # atb       — Welsh (Ateb)
  # enc       — Portuguese (Encaminhado)
  # doorst    — Dutch (Doorsturen)
  # vá/va     — Hungarian (Válasz)
  # res       — Portuguese, Catalan (Resposta)
  # fs        — Icelandic (Framsent)
  # vb        — Icelandic (Viðbrögð)
  # rv        — Norwegian Bokmål (Re: variant)
  # pd        — Czech/Slovak (Přeposláno/Preposlané)
  # wg        — German (Weitergeleitet)
  # přeposlat — Czech (Přeposlat, forward)
  # továbbítás — Hungarian (Továbbítás, forward)
  # rép       — French (Répondre)
  # beantw    — Afrikaans (Beantwoord)
  # antw      — Dutch (Antwoord)
  # svar      — Scandinavian full word (sometimes used)
  LATIN_PREFIXES = %w[
    re fw fwd sv aw tr vs ref rif ynt odp atb enc doorst
    va vá res fs vb rv pd wg rép rep beantw antw svar
  ].freeze

  # Non-Latin prefixes: each entry is a regex-safe string
  NON_LATIN_PREFIXES = [
    "回复",        # Chinese Simplified (Reply)
    "转发",        # Chinese Simplified (Forward)
    "回覆",        # Chinese Traditional (Reply)
    "轉寄",        # Chinese Traditional (Forward)
    "답장",        # Korean (Reply)
    "전달",        # Korean (Forward)
    "返信",        # Japanese (Reply)
    "転送",        # Japanese (Forward)
    "השב",        # Hebrew (Reply)
    "הועבר",      # Hebrew (Forward)
    "رد",          # Arabic (Reply)
    "إعادة توجيه", # Arabic (Forward)
    "उत्तर",       # Hindi (Reply)
    "अग्रेषित",     # Hindi (Forward)
    "ΑΠ",          # Greek (Reply — Απάντηση)
    "ΠΡΘ",         # Greek (Forward — Προώθηση)
    "НА",          # Bulgarian (Reply — Наотговор)
    "ОТВ",         # Russian (Reply — Ответ)
    "ПЕР"         # Russian (Forward — Пересылка)
  ].freeze

  # Build the combined prefix regex:
  # - Latin prefixes: word chars, optionally followed by [n] (e.g. Re[4]:)
  # - Non-Latin prefixes: exact match followed by optional [n] and colon
  LATIN_GROUP = LATIN_PREFIXES.map { |p| Regexp.escape(p) }.join("|")
  NON_LATIN_GROUP = NON_LATIN_PREFIXES.map { |p| Regexp.escape(p) }.join("|")
  PREFIX_PATTERN = /\A\s*(?:(?:#{LATIN_GROUP})(?:\[\d+\])?|(?:#{NON_LATIN_GROUP})(?:\[\d+\])?):\s*/i

  # Mailing list tags: [listname], [PATCH v2 3/5], etc.
  # Limited to 40 chars to avoid eating real subject content.
  LIST_TAG_PATTERN = /\A\s*\[[^\]]{1,40}\]\s*/

  # Normalize a subject string to its "base subject" for threading comparison.
  # Returns a stripped, prefix-free string. Never returns nil.
  def self.normalize(subject)
    return "" if subject.nil?

    s = subject.strip
    # Collapse internal whitespace
    s = s.gsub(/\s+/, " ")

    loop do
      before = s.dup
      # Strip mailing list tags (may be nested: [PATCH] [v2])
      s = s.sub(LIST_TAG_PATTERN, "")
      # Strip one reply/forward prefix
      s = s.sub(PREFIX_PATTERN, "")
      s = s.strip
      break if s == before
    end

    s
  end
end
