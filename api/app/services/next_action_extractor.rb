# Next-action fields for a Lore item (docs/Triage.md "Next-action fields"):
# a due date and an amount + currency, pulled from the subject and the newest
# message's text with plain rules — no model call.
#
# The Rust twin is `ui/desktop/core/src/next_action.rs`; both are held to the
# `next_action` cases in fixtures/parity/fixtures.json, so change them together.
#
# ponytail: regex heuristics, English + Dutch cue words. Misses an amount or a
# date phrased without a cue; move to a Jev extraction if that matters.
class NextActionExtractor
  LABELS = [TriageLabel::PAYMENT_DUE, TriageLabel::ACTION_REQUIRED, TriageLabel::NEEDS_APPROVAL,
            TriageLabel::SCHEDULING, TriageLabel::NEEDS_ANSWER].freeze
  MAX_CHARS = 8000
  CUE_WINDOW = 40 # chars before an amount searched for an amount cue

  NUM = "[0-9]{1,3}(?:[.,][0-9]{3})+(?:[.,][0-9]{1,2})?|[0-9]+(?:[.,][0-9]{1,2})?"
  SP = "[ \\t\\u00A0]"
  MONEY = /(HK\$|€|\$|£|\b(?:EUR|USD|GBP|AED|PKR))#{SP}?(#{NUM})|(#{NUM})#{SP}?(€|(?:EUR|USD|GBP|AED|PKR)\b)/
  AMOUNT_CUE = /\b(?:total|totaal|amount due|te betalen|bedrag|balance|due)\b/i
  CURRENCIES = { "€" => "EUR", "$" => "USD", "£" => "GBP", "HK$" => "HKD" }.freeze

  MONTHS = {
    "january" => 1, "januari" => 1, "jan" => 1, "february" => 2, "februari" => 2, "feb" => 2,
    "march" => 3, "maart" => 3, "mrt" => 3, "mar" => 3, "april" => 4, "apr" => 4,
    "may" => 5, "mei" => 5, "june" => 6, "juni" => 6, "jun" => 6, "july" => 7, "juli" => 7, "jul" => 7,
    "august" => 8, "augustus" => 8, "aug" => 8, "september" => 9, "sept" => 9, "sep" => 9,
    "october" => 10, "oktober" => 10, "oct" => 10, "okt" => 10, "november" => 11, "nov" => 11,
    "december" => 12, "dec" => 12
  }.freeze
  MONTH = "(#{MONTHS.keys.sort_by { |m| -m.length }.join('|')})\\b\\.?"
  FILLER = "date|datum|on|op|the|de|is|of|van|uiterlijk|vóór|voor|" \
           "monday|tuesday|wednesday|thursday|friday|saturday|sunday|" \
           "maandag|dinsdag|woensdag|donderdag|vrijdag|zaterdag|zondag"
  DUE_CUE = /\b(?:due|before|by|deadline|uiterlijk|vóór|voor|vervaldatum)\b(?:[ \t :,.]+(?:#{FILLER})\b)*[ \t :,.]*/i
  ISO = /\A([0-9]{4})-([0-9]{2})-([0-9]{2})/
  DMY = %r{\A([0-9]{1,2})[-/.]([0-9]{1,2})[-/.]([0-9]{4})}
  D_MONTH = /\A([0-9]{1,2})(?:st|nd|rd|th)?#{SP}+#{MONTH}(?:[ \t ,]+([0-9]{4}))?/i
  MONTH_D = /\A#{MONTH}#{SP}+([0-9]{1,2})(?:st|nd|rd|th)?(?:,?#{SP}+([0-9]{4}))?/i
  RELATIVE = /\b(?:within|binnen)#{SP}+([0-9]{1,3})#{SP}+(?:days?|dagen|dag)\b/i

  Result = Data.define(:due_on, :amount_cents, :currency) do
    def to_h = { "due_on" => due_on&.iso8601, "amount_cents" => amount_cents, "currency" => currency }
  end
  NONE = Result.new(due_on: nil, amount_cents: nil, currency: nil)

  # `message_date` is a Date (the newest message's UTC day).
  def self.extract(label:, subject:, text:, message_date:)
    return NONE unless LABELS.include?(label) && message_date

    hay = "#{subject}\n#{text}"[0, MAX_CHARS]
    amount = amount(hay)
    Result.new(due_on: due_on(hay, message_date), amount_cents: amount&.first, currency: amount&.last)
  end

  # Columns as stored on conversations.
  def self.attributes(...)
    r = extract(...)
    { next_action_due_on: r.due_on, next_action_amount_cents: r.amount_cents, next_action_currency: r.currency }
  end

  def self.amount(hay)
    found = hay.to_enum(:scan, MONEY).map do
      m = Regexp.last_match
      sym = m[1] || m[4]
      [cents(m[2] || m[3]), CURRENCIES.fetch(sym, sym), m.begin(0)]
    end
    return nil if found.empty?

    cued = found.find { |(_, _, at)| hay[[at - CUE_WINDOW, 0].max...at].match?(AMOUNT_CUE) }
    pick = cued || found.reduce { |best, f| f[0] > best[0] ? f : best } # largest, first on a tie
    pick.first(2)
  end

  # "1.234,56" / "1,234.56" / "386,00" / "1.234": the last separator is the
  # decimal point when 1-2 digits follow it, else a thousands separator.
  def self.cents(num)
    last = num.rindex(/[.,]/)
    if last && num.length - last - 1 <= 2
      whole = num[0...last].delete(".,")
      frac = num[(last + 1)..].ljust(2, "0")
    else
      whole = num.delete(".,")
      frac = "00"
    end
    (whole.to_i * 100) + frac.to_i
  end

  def self.due_on(hay, message_date)
    hay.to_enum(:scan, DUE_CUE).each do
      date = parse_date(hay[Regexp.last_match.end(0)..], message_date)
      return date if date
    end
    m = RELATIVE.match(hay)
    m ? message_date + m[1].to_i : nil
  end

  def self.parse_date(rest, message_date)
    if (m = ISO.match(rest))
      on_or_after(m[1].to_i, m[2].to_i, m[3].to_i, message_date)
    elsif (m = DMY.match(rest))
      on_or_after(m[3].to_i, m[2].to_i, m[1].to_i, message_date)
    elsif (m = D_MONTH.match(rest))
      with_year(m[3], MONTHS.fetch(m[2].downcase), m[1].to_i, message_date)
    elsif (m = MONTH_D.match(rest))
      with_year(m[3], MONTHS.fetch(m[1].downcase), m[2].to_i, message_date)
    end
  end

  # No year: this year's date, or next year's when that has already passed.
  def self.with_year(year, month, day, message_date)
    return on_or_after(year.to_i, month, day, message_date) if year

    on_or_after(message_date.year, month, day, message_date) ||
      on_or_after(message_date.year + 1, month, day, message_date)
  end

  def self.on_or_after(year, month, day, message_date)
    return nil unless Date.valid_date?(year, month, day)

    date = Date.new(year, month, day)
    date >= message_date ? date : nil
  end
  private_class_method :amount, :cents, :due_on, :parse_date, :with_year, :on_or_after
end
