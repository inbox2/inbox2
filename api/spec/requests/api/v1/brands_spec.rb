require "rails_helper"

# Brand lookup (docs/plans/lore.md §4b Imagery): GET /api/v1/brands/:domain.
RSpec.describe "Api::V1::Brands", type: :request do
  let(:user) { create(:user, username: "branduser") }
  let(:headers) { auth_headers(user) }
  let(:brand) { response.parsed_body["brand"] }

  let(:html) do
    <<~HTML
    <html><head>
      <title>  Odido | Mobiel   </title>
      <meta property="og:site_name" content="Odido">
      <meta property="og:image" content="/img/hero.jpg">
      <meta name="theme-color" content="#F0A">
      <link rel="icon" href="/favicon-16.png" sizes="16x16">
      <link rel="apple-touch-icon" href="icons/touch.png" sizes="180x180">
      <link rel="icon" href="javascript:alert(1)" sizes="999x999">
    </head><body></body></html>
    HTML
  end

  def proxied(url) = "/api/v1/image-proxy?url=#{ERB::Util.url_encode(url)}"

  def ok(body)
    [Net::HTTPOK.new("1.1", "200", "OK"), body]
  end

  def redirect(location)
    [Net::HTTPFound.new("1.1", "302", "Found").tap { |r| r["Location"] = location }, ""]
  end

  before do
    allow(PrivateAddressGuard).to receive(:resolve).and_wrap_original do |orig, host|
      case host
      when "odido.nl", "www.odido.nl" then ["93.184.216.34"]
      when "intranet.example" then ["10.0.0.5"]
      else orig.call(host)
      end
    end
  end

  describe "GET /api/v1/brands/:domain" do
    context "positive" do
      it "parses name, og:image, theme-color and the largest icon, resolving relative URLs against the final URL" do
        allow_any_instance_of(BrandFetcher).to receive(:get) do |_, uri, _ip|
          uri.host == "odido.nl" ? redirect("https://www.odido.nl/nl/") : ok(html)
        end

        get "/api/v1/brands/WWW.Odido.nl", headers: headers
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body.keys).to eq(["brand"])
        expect(brand).to eq(
          "domain" => "odido.nl",
          "name" => "Odido",
          "icon_url" => proxied("https://www.odido.nl/nl/icons/touch.png"),
          "image_url" => proxied("https://www.odido.nl/img/hero.jpg"),
          "theme_color" => "#ff00aa"
        )
      end

      it "falls back to <title> and /favicon.ico" do
        allow_any_instance_of(BrandFetcher).to receive(:get).and_return(ok("<html><head><title> Odido  Home </title></head></html>"))

        get "/api/v1/brands/odido.nl", headers: headers
        expect(brand).to include("name" => "Odido Home", "image_url" => nil, "theme_color" => nil,
                                 "icon_url" => proxied("https://odido.nl/favicon.ico"))
      end

      it "returns all-null fields for a freemail domain without fetching" do
        expect_any_instance_of(BrandFetcher).not_to receive(:get)

        get "/api/v1/brands/gmail.com", headers: headers
        expect(response).to have_http_status(:ok)
        expect(brand).to eq("domain" => "gmail.com", "name" => nil, "icon_url" => nil, "image_url" => nil, "theme_color" => nil)
      end

      it "serves a cache hit without refetching" do
        allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
        calls = 0
        allow_any_instance_of(BrandFetcher).to receive(:get) { calls += 1; ok(html) }

        2.times { get "/api/v1/brands/odido.nl", headers: headers }
        expect(calls).to eq(1)
        expect(brand["name"]).to eq("Odido")
      end
    end

    context "negative" do
      it "rejects an invalid domain with 422" do
        ["not a domain", "localhost", "foo_bar.com", "-x.com", "1.2.3.4"].each do |bad|
          get "/api/v1/brands/#{ERB::Util.url_encode(bad)}", headers: headers
          expect(response).to have_http_status(:unprocessable_content), bad
          expect(response.parsed_body["errors"].first["message"]).to eq("Invalid domain")
        end
      end

      it "rejects an unauthenticated request" do
        get "/api/v1/brands/odido.nl"
        expect(response).to have_http_status(:unauthorized)
      end

      it "refuses a domain resolving to a private address (SSRF guard) and returns nulls" do
        expect_any_instance_of(BrandFetcher).not_to receive(:get)

        get "/api/v1/brands/intranet.example", headers: headers
        expect(response).to have_http_status(:ok)
        expect(brand.except("domain").values).to all(be_nil)
      end

      it "refuses a redirect to a private address" do
        allow_any_instance_of(BrandFetcher).to receive(:get).and_return(redirect("http://127.0.0.1/admin"))

        get "/api/v1/brands/odido.nl", headers: headers
        expect(brand.except("domain").values).to all(be_nil)
      end

      it "returns nulls (not 5xx) when the fetch fails" do
        allow_any_instance_of(BrandFetcher).to receive(:get).and_raise(Net::OpenTimeout)

        get "/api/v1/brands/odido.nl", headers: headers
        expect(response).to have_http_status(:ok)
        expect(brand.except("domain").values).to all(be_nil)
      end
    end
  end
end
