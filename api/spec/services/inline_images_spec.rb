require "rails_helper"

RSpec.describe InlineImages do
  it "turns data: images into cid: parts, one part per distinct image" do
    png = Base64.strict_encode64("PNGDATA")
    html = %(<p><img src="data:image/png;base64,#{png}"><img src='data:image/png;base64,#{png}'><img src="https://x/y.png"></p>)
    out, parts = described_class.extract(html)
    expect(parts.size).to eq(1)
    expect(parts.first.data).to eq("PNGDATA")
    expect(out.scan("cid:#{parts.first.content_id}").size).to eq(2)
    expect(out).to include("https://x/y.png")
    expect(out).not_to include("data:")
  end

  it "leaves HTML without data images alone" do
    expect(described_class.extract("<p>hi</p>")).to eq(["<p>hi</p>", []])
  end
end
