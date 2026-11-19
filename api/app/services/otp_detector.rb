# Sign-in codes and one-click sign-in links in a just-arrived email, so the
# alert (mobile push + desktop card) can offer Copy / Open link instead of
# making you open the thread (docs/Notifications.md "Sign-in codes and links").
# The Rust twin is ui/desktop/core/src/otp.rs (local channels); both are locked
# to the `otp` cases in fixtures/parity/fixtures.json.
#
# ponytail: keyword + proximity heuristics, English and Dutch only. Misses a
# code that sits far from any keyword; upgrade to a Jev judgment if it misfires.
module OtpDetector
  module_function

  # The mail has to be about signing in at all — this keeps a promo's "use code
  # SAVE20" or an "Order confirmation" off the card. Bare "confirm" or
  # "verified" is not enough: an order or a review says those too.
  # How far into the text a sign-in cue may sit for a link (not a code) to count.
  LINK_LEAD_CHARS = 600
  # An unsubscribe footer: bulk mail, never a one-off sign-in link.
  BULK = /unsubscribe|uitschrijven|afmelden voor|afmelden|manage (?:your )?(?:e-?mail )?preferences|e-?mail preferences|nieuwsbrief/i
  SIGN_IN = /verification|\bverify\b|one[- ]time|\botp\b|passcode|security code|sign[- ]?in|log[- ]?in|\blogin\b|two[- ]factor|\b2fa\b|authenticat|confirm your (?:e-?mail|account|sign|log)|magic link|inlog|toegangscode|verificatie/i
  # Words a code follows ("Your code is 482910", "Uw code: 4829").
  # `code\b` keeps "passcode"/"verificatiecode" but not "codes"/"codebase" — a
  # commit message reading "Sign-in codes…" made a GitLab mail a sign-in card.
  CODE_WORD = /code\b|\bpin\b|\botp\b/i
  # A code: "123 456"/"123-456", 4–8 digits, or 6–8 upper-case letters + digits.
  CODE = /\b(\d{3}[ -]\d{3}|\d{4,8}|(?=[A-Z0-9]*\d)(?=[A-Z0-9]*[A-Z])[A-Z0-9]{6,8})\b/
  DIGITS = /\b(\d{4,8})\b/
  ANCHOR = /<a\b[^>]*?\bhref\s*=\s*["']([^"']+)["'][^>]*>(.*?)<\/a>/im
  # Link ranking, strongest first: the button names the sign-in, then the URL
  # does, then a generic "Continue"/"Confirm" button.
  LINK_TEXT = /sign[- ]?in|log[- ]?in|\blogin\b|verify|magic|activate|inloggen|aanmelden|bevestig/i
  LINK_HREF = /token|magic|verif|validat|login|signin|sign-in|auth|confirm/i
  LINK_TEXT_WEAK = /continue|confirm|open/i
  NOT_THIS_LINK = /unsubscribe|privacy|terms|help|support|preferences|afmelden/i

  # {"code" => …}, {"link" => …, "host" => …}, or nil. A code wins when the
  # mail carries both.
  def detect(subject:, body_plain:, body_html:, snippet:)
    subject = subject.to_s
    text = (body_plain.presence || snippet.to_s)[0, 5000]
    return nil unless subject.match?(SIGN_IN) || text.match?(SIGN_IN)

    # URLs out first: a token in a magic link ("…/login/eyJ…") is not a code.
    code = find_code(subject, text.gsub(%r{https?://\S+}, " "))
    return { "code" => code } if code

    # A link needs more than a sign-in word anywhere (a newsletter's footer "log in
    # to your account" + its tracking links read as a magic link, 2026-10-20): the
    # subject names the sign-in, or the opening lines do in a mail with no
    # unsubscribe footer. Codes keep the looser gate. Mirrors otp::detect.
    html = body_html.to_s[0, 200_000]
    lead_ok = text[0, LINK_LEAD_CHARS].match?(SIGN_IN) && !text.match?(BULK) && !html.match?(BULK)
    return nil unless subject.match?(SIGN_IN) || lead_ok

    link = find_link(html, text)
    host = link && URI.parse(link).then { |u| u.port == u.default_port ? u.host : "#{u.host}:#{u.port}" }
    host.present? ? { "link" => link, "host" => host } : nil
  rescue URI::InvalidURIError
    nil
  end

  def find_code(subject, text)
    text.to_enum(:scan, CODE_WORD).each do
      after = Regexp.last_match.end(0)
      hit = text[after, 80].to_s[CODE, 1]
      return hit if hit
    end
    # "482910 is your Instagram code" — the code comes first, in a subject that
    # says so itself. Not any number in any subject: "Failed pipeline | 30931582"
    # is a commit hash.
    return nil unless subject.match?(CODE_WORD) || subject.match?(SIGN_IN)

    subject[DIGITS, 1]
  end

  def find_link(html, text)
    anchors = html.scan(ANCHOR).map do |href, inner|
      [ href.strip.gsub("&amp;", "&").gsub("&quot;", '"').gsub("&#39;", "'"), inner.gsub(/<[^>]*>/, " ") ]
    end
    anchors.select! { |href, label| href.match?(%r{\Ahttps://}i) && !href.match?(NOT_THIS_LINK) && !label.match?(NOT_THIS_LINK) }
    hit = anchors.find { |_, label| label.match?(LINK_TEXT) } ||
          anchors.find { |href, _| href.match?(LINK_HREF) } ||
          anchors.find { |_, label| label.match?(LINK_TEXT_WEAK) }
    return hit[0] if hit

    # Plain-text mail: a bare URL that looks like a sign-in link.
    text.scan(%r{https://[^\s<>"')\]]+}).find { |u| u.match?(LINK_HREF) && !u.match?(NOT_THIS_LINK) }
  end
end
