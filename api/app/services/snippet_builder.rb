# Builds the one-line conversation preview from a message body. Prefers the
# HTML part stripped to bare text, like Gmail: senders neglect the text/plain
# alternative (a "your client can't display HTML" stub, or a stale template in
# another language), so it disagrees with what the reader sees. Falls back to
# the plain part for plain-only or image-only mail.
#
# Some senders leak CSS rules into the text/plain part verbatim ("* {
# font-family: Arial !important; }" as the first text in the mail) and pad the
# preview with invisible characters (zero-width joiners after every glyph) so
# mail clients show an empty-looking preheader. Both would land at the front of
# the stored snippet, so they're stripped before whitespace is collapsed and
# the result truncated. HTML entities left behind after tag stripping
# ("&amp;", "&#39;", "&nbsp;") are decoded so they don't render literally.
#
# Mirror of the Rust core's `build_snippet` (ui/desktop/core/src/sync/
# threading.rs) — keep the two in sync.
#
# Usage:
#   SnippetBuilder.build("* { font-family: Arial; } Hello")
#   # => "Hello"
#   SnippetBuilder.build(nil, "<p>Meta &amp; you</p>")
#   # => "Meta & you"
class SnippetBuilder
  MAX_LENGTH = 200

  # Invisible format characters used as preview-pane padding: zero-width
  # (non-)joiners/spaces, word joiners, BOMs, soft hyphens and the combining
  # grapheme joiner. They aren't whitespace, so they'd survive the collapse
  # below and eat the length budget while rendering as nothing.
  INVISIBLE = /[\u200B-\u200D\u2060\uFEFF\u00AD\u034F]/

  # Decorative separator runs — three or more consecutive divider characters
  # (`====`, `----`, `*~*~`, `———`, box-drawing lines) that plain-text mail
  # uses as horizontal rules. Gmail drops these from its preview; without this
  # a notification body fills up with `====…` before the real content. Runs of
  # one or two ("--", "C++") are kept. Mirrors the Rust core's
  # `strip_separator_runs`.
  SEPARATOR_RUN = /[=\-_*~#\u2013-\u2015\u2500-\u257F]{3,}/

  # An HTML entity: `&` + a numeric (`#39`, `#x2019`) or named (`amp`) body +
  # `;`. gsub scans the source left-to-right and never re-scans its own
  # replacements, so decoding is single-pass: `&amp;lt;` decodes to `&lt;`,
  # not `<`.
  ENTITY = /&(#x[0-9a-fA-F]+|#[0-9]+|[A-Za-z][A-Za-z0-9]*);/

  # An entity reference a hard line break splits in two. Senders wrap the raw
  # body at the SMTP 998-byte line limit without regard for entity boundaries
  # ("…&nbsp" + newline + ";&#8204;…"), and the HTML parser then decodes the
  # truncated reference (`&nbsp` is a legacy no-semicolon form) and leaves the
  # tail as literal text in the preview. Mirrors the Rust core's
  # `join_wrapped_entities`.
  WRAPPED_ENTITY = /&([#0-9A-Za-z]{0,12}\s[\s#0-9A-Za-z]{0,12});/

  # Recognisable HTML element names — the tags marketing/newsletter/ad-builder
  # mail actually emits. Kept in sync with the Rust core's `HTML_TAGS`.
  HTML_TAGS = %w[
    html head body title meta link style script div span p br hr a img table
    thead tbody tfoot tr td th ul ol li dl dt dd h1 h2 h3 h4 h5 h6 strong b i
    em u small sup sub font center blockquote pre code form input button
    textarea select option label header footer section article nav main aside
    figure figcaption picture source map area
  ].freeze

  # An opening/closing tag whose name is a known element and is terminated by
  # whitespace, `>`, or `/` — so prose like `<pretend to>` doesn't match on
  # `pre`. Used to spot HTML source lacking a leading doctype.
  HTML_TAG = %r{</?(?:#{HTML_TAGS.join('|')})(?=[\s/>]|\z)}i

  # Named entities mail senders actually emit, mapped to their character.
  # Deliberately omits `lt`/`gt` (their numeric forms are filtered in
  # `decode_entity` too): stored snippets are re-parsed as HTML by some
  # consumers, so a decoded angle bracket could turn escaped text back into
  # live markup.
  NAMED_ENTITIES = {
    "amp" => "&", "quot" => '"', "apos" => "'",
    "nbsp" => " ", "ensp" => " ", "emsp" => " ", "thinsp" => " ",
    "rsquo" => "’", "lsquo" => "‘", "rdquo" => "”", "ldquo" => "“",
    "mdash" => "—", "ndash" => "–", "hellip" => "…", "bull" => "•",
    "middot" => "·", "copy" => "©", "reg" => "®", "trade" => "™",
    "deg" => "°", "euro" => "€", "pound" => "£", "yen" => "¥",
    "cent" => "¢", "laquo" => "«", "raquo" => "»", "plusmn" => "±",
    "times" => "×", "frac12" => "½", "frac14" => "¼",
    # Invisible-format entities decode to their characters so the INVISIBLE
    # pass strips them with the rest of the padding.
    "zwnj" => "‌", "zwj" => "‍", "shy" => "­"
  }.freeze

  class << self
    def build(body_plain, body_html = nil)
      # Close up wrapped references before anything parses them.
      plain = join_wrapped_entities(body_plain.to_s)
      body_html = join_wrapped_entities(body_html.to_s)
      text = strip_html(body_html)
      if text.strip.empty?
        # Some senders put their HTML *source* in the text/plain part (so the
        # preview would otherwise read "<!DOCTYPE html> <html> <head>…").
        # Strip the tags in that case, same as the HTML path.
        text = looks_like_html_source(plain) ? strip_html(plain) : plain
      end
      sanitize(text)
    end

    # Decode entities, strip leaked CSS + invisible padding + bare URLs +
    # separator runs, collapse whitespace to one line, truncate. A clean
    # snippet is a fixed point of this function (the iOS/desktop open-time
    # scrub relies on that).
    def sanitize(text)
      decoded = decode_html_entities(text).gsub(INVISIBLE, "")
      # Separator strip runs after URL strip so a dashed URL path is removed
      # whole rather than broken mid-link. Hard-cut to MAX_LENGTH characters
      # (no ellipsis), matching the Rust core's `.chars().take(200)`.
      strip_cids(strip_urls(strip_css_rules(decoded)))
        .gsub(SEPARATOR_RUN, " ").split.join(" ")[0, MAX_LENGTH] || ""
    end

    private

    # Rejoin entity references broken by the sender's line wrapping. Only joined
    # when the whitespace-free body is a reference we know, so prose ("R & D;")
    # is left exactly as written.
    def join_wrapped_entities(text)
      text.gsub(WRAPPED_ENTITY) do
        # Both captures are read BEFORE the inner gsub — that call resets
        # `Regexp.last_match`, so reading it afterwards yields the `\s+` match.
        whole = Regexp.last_match(0)
        body = Regexp.last_match(1).gsub(/\s+/, "")
        decode_entity(body) ? "&#{body};" : whole
      end
    end

    # True when text is actually HTML source rather than prose — a tag soup that
    # would read as gibberish in a one-line preview. Fires when the content
    # opens with a document/root marker, *or* when it carries two or more
    # recognisable HTML element tags (`<div>`, `<td>`, `<input …>`, `</p>` …) —
    # the case where a sender crams the HTML *source* into the text/plain part
    # without a leading doctype (marketing/ad-builder mail). Conservative on
    # prose: a stray `<` ("a < b") or a lone `<placeholder>` word never trips it,
    # because a name must match a known element and at least two must be present.
    # Mirrors the Rust core's `looks_like_html_source`.
    def looks_like_html_source(text)
      head = text.lstrip[0, 15].to_s.downcase
      return true if head.start_with?("<!doctype") || head.start_with?("<html")

      text.scan(HTML_TAG).size >= 2
    end

    # Remove bare URLs from a one-line preview. Marketing/notification mail
    # inlines long tracking links in the text/plain part — e.g. "… Hero image (
    # https://clicks.example.com/f/a/6tE-…" — which would otherwise fill the
    # notification body with an opaque URL. Drop a URL together with its
    # `( )`/`[ ]`/`< >` wrapper when wrapped, then any remaining bare URL.
    def strip_urls(text)
      text
        .gsub(%r{[(\[<]\s*https?://\S+?\s*[)\]>]}i, " ")
        .gsub(%r{https?://\S+}i, " ")
    end

    # Remove inline content-id image placeholders that some senders leak into
    # the text/plain alternative where an inline image sat — e.g. "Kindly
    # approve the change [cid:logo_ecbea85b-c03e-44b5-a1f2@inbox2]". Without
    # this the raw `cid:` token fills the notification body (the reported bug).
    # Drops the cid reference together with its `( )`/`[ ]`/`< >` wrapper, then
    # any remaining bare `cid:` ref. Mirrors strip_urls; idempotent.
    def strip_cids(text)
      text
        .gsub(/[(\[<]\s*cid:[^)\]>\s]*\s*[)\]>]/i, " ")
        .gsub(/\bcid:[^\s)\]>]+/i, " ")
    end

    # Strip HTML tags to bare text. Rails' full sanitizer re-serializes, so
    # `&`/`<`/`>` stay escaped (decoded by the entity pass). It keeps
    # `<style>`/`<script>` *contents* though, and strip_css_rules can't drop an
    # `@media only screen and (max-width: 520px)` prelude, so newsletter
    # snippets (and MX notifications) read "@media only screen…" — drop those
    # blocks first, matching the Rust core's `ammonia` pass.
    def strip_html(html)
      return "" if html.strip.empty?

      ActionController::Base.helpers.strip_tags(html.gsub(%r{<(style|script)\b[^>]*>.*?</\1\s*>}im, " "))
    end

    # Single-pass entity decode. Unknown entities pass through unchanged.
    def decode_html_entities(text)
      text.gsub(ENTITY) { decode_entity(Regexp.last_match(1)) || Regexp.last_match(0) }
    end

    # Decode one entity body (between `&` and `;`), or nil to leave it as-is.
    # Filters control characters and angle brackets from numeric refs for the
    # same reason NAMED_ENTITIES omits `lt`/`gt`.
    def decode_entity(name)
      return NAMED_ENTITIES[name] unless name.start_with?("#")

      num = name[1..]
      code = num.start_with?("x", "X") ? num[1..].to_i(16) : num.to_i
      char = begin
        code.chr(Encoding::UTF_8)
      rescue RangeError
        return nil
      end
      return nil if char == "<" || char == ">"
      # Tab/CR/LF references (`&#x0009;`, a mail-merge leftover) become a space —
      # the control-character filter below would leave them in verbatim.
      return " " if ["\t", "\n", "\r"].include?(char)
      return nil if code < 0x20 || code.between?(0x7F, 0x9F)

      char
    end

    # Remove CSS rule blocks — `selector { prop: value; }` — including the
    # selector tokens directly before them. Brace blocks whose content is not
    # declaration-shaped (prose like "use {braces} wisely") are kept untouched.
    def strip_css_rules(text)
      out = +""
      rest = text
      while (open_at = rest.index("{"))
        close_at = matching_brace(rest, open_at)
        break if close_at.nil?

        if css_declarations?(rest[(open_at + 1)...close_at])
          out << trim_selector_suffix(rest[0...open_at]) << " "
        else
          out << rest[0..close_at]
        end
        rest = rest[(close_at + 1)..] || ""
      end
      out << rest
    end

    # Index of the brace closing the one at `open_at` (depth-tracked for
    # nested @media blocks), or nil when unbalanced.
    def matching_brace(text, open_at)
      depth = 0
      (open_at...text.length).each do |i|
        case text[i]
        when "{" then depth += 1
        when "}"
          depth -= 1
          return i if depth.zero?
        end
      end
      nil
    end

    # Whether brace-block content reads as CSS declarations (`property: value`,
    # `;`-separated, property names alphanumeric-with-dashes) or wraps a nested
    # rule (an `@media` body).
    def css_declarations?(inner)
      return true if inner.include?("{")

      inner.split(";").any? do |decl|
        prop, sep, val = decl.partition(":")
        sep == ":" && val.strip.present? && prop.strip.match?(/\A[A-Za-z0-9-]+\z/)
      end
    end

    # Drop the selector tokens directly before a stripped CSS block: tokens
    # carrying CSS marker characters (* . # @ : > [) always go; one plain
    # tag-like word ("body", "td") goes only right before the brace; comma-ended
    # tokens continue a selector list. Ordinary prose before the rule stays.
    def trim_selector_suffix(prefix)
      keep = prefix.rstrip
      first = true
      6.times do
        token = keep.split.last
        break if token.nil?

        tag_like = token.length <= 10 && token.match?(/\A[A-Za-z][A-Za-z0-9-]*\z/)
        break unless token.match?(/[*.#@:>\[]/) || token.end_with?(",") || (first && tag_like)

        keep = keep[0...-token.length].rstrip
        first = false
      end
      keep
    end
  end
end
