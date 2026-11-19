require "rails_helper"

RSpec.describe SnippetBuilder do
  describe ".build" do
    it "passes ordinary text through, whitespace-collapsed" do
      expect(described_class.build("hi   there\nfriend")).to eq("hi there friend")
    end

    it "returns an empty string for nil" do
      expect(described_class.build(nil)).to eq("")
    end

    it "strips leaked CSS rules and invisible preheader padding" do
      # The field case: a marketing text/plain part that opens with a CSS rule
      # and pads the preview with zero-width junk after every glyph.
      body = "Vestiaire Collective    * { font-family: Arial,\nsans-serif !important; }" \
             "   Maybe it’s time͏‌ ͏‌ ͏‌"
      expect(described_class.build(body)).to eq("Vestiaire Collective Maybe it’s time")
    end

    it "strips selector lists and nested @media bodies" do
      body = "Hi! .btn, a:hover { color: red } @media all { td { margin: 0 } } Sale on now"
      expect(described_class.build(body)).to eq("Hi! Sale on now")
    end

    it "keeps prose braces that are not declaration-shaped" do
      expect(described_class.build("use {braces} wisely")).to eq("use {braces} wisely")
    end

    it "hard-cuts to 200 characters with no ellipsis (matches the Rust core)" do
      result = described_class.build("a" * 300)
      expect(result).to eq("a" * 200)
      expect(result).not_to include("...")
    end

    it "strips HTML source pasted into the text/plain part (matches the Rust core)" do
      expect(described_class.build("<!DOCTYPE html><html><body>Hello there</body></html>")).to eq("Hello there")
      # A stray '<' in genuine prose is left alone.
      expect(described_class.build("if a < b then ok")).to eq("if a < b then ok")
    end

    it "strips HTML source lacking a leading doctype (the ad-builder/marketing case)" do
      body = %(<div class="card">\n  <h2>Cold-call pain</h2>\n) \
             "  <textarea>Buyer ko call karna band karo.</textarea>\n" \
             "  <button>Create draft ad</button>\n</div>"
      expect(described_class.build(body)).to eq("Cold-call pain Buyer ko call karna band karo. Create draft ad")
      # One tag alone, or unknown "tag" words, stay prose — no over-stripping.
      expect(described_class.build("email me at <a>")).to eq("email me at <a>")
      expect(described_class.build("use <name> and <place> placeholders"))
        .to eq("use <name> and <place> placeholders")
      expect(described_class.build("compare 5 < 10 and 10 > 5")).to eq("compare 5 < 10 and 10 > 5")
    end

    it "rejoins entity references split by the sender's line wrapping" do
      # The field case: Thuisbezorgd's preheader padding, hard-wrapped at the
      # SMTP 998-byte line limit mid-reference, so the push notification read
      # "Be a star and leave a review ; R 04; &n bsp; & #8204; …".
      body = "<div>Be a star and leave a review</div>\n" \
             "<div>&nbsp;&#8204;&nbsp\n;&#8204;&nbsp;&#820\n4;</div>\n" \
             "<p>Would you recommend them?</p>"
      expect(described_class.build(body)).to eq("Be a star and leave a review Would you recommend them?")
      expect(described_class.build("3&nbsp\n;new &#82\n04;updates")).to eq("3 new updates")
    end

    it "leaves prose that merely straddles a line break alone" do
      expect(described_class.build("R &\nD; and Q&A")).to eq("R & D; and Q&A")
    end

    it "decodes tab references instead of showing them raw" do
      expect(described_class.build("Telefoon:010-4769447 &#x0009;&#x0009;De heer"))
        .to eq("Telefoon:010-4769447 De heer")
    end

    it "decodes HTML entities left in the plain part" do
      expect(described_class.build("Meta &amp; you &#8211; you&#39;ve got 3&nbsp;updates&hellip;"))
        .to eq("Meta & you – you've got 3 updates…")
    end

    it "falls back to the HTML part for HTML-only mail, stripped and decoded" do
      # The field case: a notification email with no text/plain part.
      html = "<p>Meta &amp; you &#8211; you&#39;ve got 3&nbsp;new updates&hellip;</p>"
      expect(described_class.build(nil, html)).to eq("Meta & you – you've got 3 new updates…")
    end

    it "prefers the HTML part when both are present (Gmail-style)" do
      expect(described_class.build("plain loses", "<p>html wins</p>")).to eq("html wins")
    end

    it "drops <style> blocks whole, @media preludes included" do
      html = "<html><head><style>@media only screen and (min-width: 520px) { .u-row { width: 500px !important; } }</style></head>" \
             "<body><p>Explore user behavior</p><script>var x = 1;</script></body></html>"
      expect(described_class.build(nil, html)).to eq("Explore user behavior")
    end

    it "falls back to the plain part when the HTML strips to nothing" do
      expect(described_class.build("plain fallback", '<img src="x">')).to eq("plain fallback")
    end

    it "falls back to HTML when the plain part is blank" do
      expect(described_class.build("   ", "<p>fallback</p>")).to eq("fallback")
    end

    it "decodes the hex numeric entity form" do
      expect(described_class.build("it&#x2019;s here")).to eq("it’s here")
    end

    it "decodes invisible-format entities then strips them as padding" do
      expect(described_class.build("pad&#8203;ded&zwnj; text")).to eq("padded text")
    end

    it "decodes one level only (single pass) and never emits markup" do
      expect(described_class.build("&amp;lt;b&amp;gt;")).to eq("&lt;b&gt;")
      # lt/gt (named or numeric) stay escaped so snippets can't become live markup.
      expect(described_class.build("&lt;img onerror=x&gt; &#60;b&#62;"))
        .to eq("&lt;img onerror=x&gt; &#60;b&#62;")
    end

    it "passes unknown entities and bare ampersands through unchanged" do
      expect(described_class.build("AT&T; R&D and Q&A")).to eq("AT&T; R&D and Q&A")
    end

    it "strips an inline tracking URL together with its wrapper" do
      # The field case: a marketing text/plain part with a wrapped tracking link.
      body = "Nu live in de nieuwste 96 Hero image " \
             "( https://clicks.treatwell.com/f/a/6tE-ICN4hzqPMl7BfMqPEg~~/AAAHahA~/NFtcpMkHm7uRbZd ) Boek nu"
      expect(described_class.build(body)).to eq("Nu live in de nieuwste 96 Hero image Boek nu")
    end

    it "strips a bare URL mid-sentence" do
      expect(described_class.build("Reset your password at https://example.com/reset?t=abc now"))
        .to eq("Reset your password at now")
    end

    it "strips a leaked [cid:] inline-image placeholder with its wrapper" do
      # The reported case: an inline-image content-id leaked into the
      # text/plain part fills the notification body with "[cid:logo_…]".
      body = "Kindly approve Mandatory 'Component' Field " \
             "[cid:logo_ecbea85b-c03e-44b5-a1f2@inbox2]"
      expect(described_class.build(body)).to eq("Kindly approve Mandatory 'Component' Field")
    end

    it "strips bracket variants and a bare cid: ref" do
      expect(described_class.build("See <cid:abc@x> the logo")).to eq("See the logo")
      expect(described_class.build("Logo ( cid:abc@x ) here")).to eq("Logo here")
      expect(described_class.build("Top cid:hero_42@mail bottom")).to eq("Top bottom")
    end

    it "leaves a literal 'cid:' with no content-id untouched" do
      expect(described_class.build("the cid: prefix")).to eq("the cid: prefix")
    end
  end

  describe ".sanitize" do
    it "leaves a clean snippet unchanged (fixed point for the client scrub)" do
      clean = "You're mentioned in a comment — reply now"
      expect(described_class.sanitize(clean)).to eq(clean)
    end

    it "treats an entity-laden snippet as dirty (so the client scrub rebuilds it)" do
      stored = "You&#39;re mentioned in a comment&nbsp;&mdash; reply now"
      expect(described_class.sanitize(stored)).not_to eq(stored)
    end
  end
end
