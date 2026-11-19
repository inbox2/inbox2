require "rails_helper"

RSpec.describe PlainBodyHtml do
  it "returns nil for a blank body" do
    expect(described_class.call(nil)).to be_nil
    expect(described_class.call("  ")).to be_nil
  end

  it "escapes, breaks lines, links URLs and collapses the quote into one blockquote" do
    html = described_class.call("Hi <you> & co\nsee https://x.test/a?b=1.\n\n> On Mon, A wrote:\n> old text")

    expect(html).to include("Hi &lt;you&gt; &amp; co<br>")
    expect(html).to include(%(<a href="https://x.test/a?b=1">https://x.test/a?b=1</a>.))
    expect(html.scan("<blockquote").size).to eq(1)
    expect(html).to include("On Mon, A wrote:<br>old text</blockquote>")
    expect(html).not_to include("&gt; old")
  end
end
