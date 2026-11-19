require "rails_helper"

# CORS allow-list (config/application.rb).
#
# The desktop bundle's webview is its own origin — `tauri://localhost` on macOS,
# `http(s)://tauri.localhost` on Windows/Linux — so every call it makes to the API
# is cross-origin. It authenticates with a Bearer token from the engine's
# encrypted store, not the session cookie. Those origins are allowed
# unconditionally rather than through FRONTEND_URL, so a deploy can't drop them
# by changing one env var. See docs/Tauri-Desktop.md ("Which API each bundle
# talks to").
RSpec.describe "CORS", type: :request do
  def preflight(origin)
    process(:options, "/api/v1/plans", headers: {
      "HTTP_ORIGIN" => origin,
      "HTTP_ACCESS_CONTROL_REQUEST_METHOD" => "GET"
    })
    response.headers["access-control-allow-origin"]
  end

  describe "desktop webview origins" do
    # rack-cors only passes a literal through when it already carries a scheme;
    # anything else is rewritten to `http://<value>`, which would silently never
    # match the custom tauri scheme. These assert the real header, not the config.
    %w[tauri://localhost http://tauri.localhost https://tauri.localhost].each do |origin|
      it "allows #{origin}" do
        expect(preflight(origin)).to eq(origin)
      end
    end
  end

  describe "the configured web frontend" do
    it "allows the FRONTEND_URL origin" do
      expect(preflight("http://localhost:4173")).to eq("http://localhost:4173")
    end
  end

  describe "the public desktop-release endpoints" do
    # The marketing site lives on a different origin from the web app, and these
    # two paths are read-only, unauthenticated and carry no credentials — so they
    # allow any origin. The allow-list above has to stay shut for everything else.
    def release_preflight(origin, path)
      process(:options, path, headers: {
        "HTTP_ORIGIN" => origin,
        "HTTP_ACCESS_CONTROL_REQUEST_METHOD" => "GET"
      })
      response.headers["access-control-allow-origin"]
    end

    %w[/api/v1/desktop/releases/latest /downloads/desktop/latest.json].each do |path|
      it "allows any origin on #{path}" do
        expect(release_preflight("https://inbox2.com", path)).to eq("*")
      end
    end

    it "still refuses that origin on an ordinary endpoint" do
      expect(preflight("https://inbox2.com")).to be_nil
    end
  end

  describe "everything else" do
    it "does not allow an unlisted origin" do
      expect(preflight("https://evil.example")).to be_nil
    end

    it "does not reflect an origin that merely contains an allowed one" do
      expect(preflight("https://tauri.localhost.evil.example")).to be_nil
    end
  end
end
