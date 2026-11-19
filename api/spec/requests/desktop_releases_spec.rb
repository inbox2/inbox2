require "rails_helper"

# Desktop app distribution: the Tauri updater manifest, the binary redirect and
# the /console download list, all backed by the Pushleft bucket. The bucket is
# faked as an in-memory { key => body } map behind DesktopReleases.objects/read.
RSpec.describe "Desktop releases" do
  let(:bucket) { {} }

  def seed_release(version, files)
    files.each { |name, body| bucket["#{version}/#{name}"] = body }
  end

  before do
    allow(DesktopReleases).to receive(:objects) { bucket.transform_values(&:bytesize) }
    allow(DesktopReleases).to receive(:read) { |key| bucket[key] }
  end

  describe "GET /downloads/desktop/latest.json" do
    it "serves the newest version's manifest with a short cache (positive)" do
      seed_release("1.0.0", "latest.json" => '{"version":"0.9.0","platforms":{}}')
      seed_release("1.2.0", "latest.json" => '{"version":"1.2.0","platforms":{"linux-x86_64":{}}}')

      get "/downloads/desktop/latest.json"

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("application/json")
      body = JSON.parse(response.body)
      expect(body["version"]).to eq("1.2.0") # picked the newest, not 1.0.0
      # Short TTL so a new build isn't masked by a long cache.
      expect(response.headers["Cache-Control"]).to include("max-age=60")
    end

    it "404s when no build is published (negative)" do
      get "/downloads/desktop/latest.json"
      expect(response).to have_http_status(:not_found)
    end

    # bin/release-desktop copies latest.json last, so a newer directory without
    # one is an upload in progress. Ranking it would 404 every client's update
    # check for the minutes a release takes to copy.
    it "ignores a newer release whose manifest has not landed yet (negative)" do
      seed_release("1.2.0", "latest.json" => '{"version":"1.2.0","platforms":{}}')
      seed_release("1.3.0", "Inbox2_1.3.0_aarch64.dmg" => "half-copied")

      get "/downloads/desktop/latest.json"

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["version"]).to eq("1.2.0")
    end
  end

  describe "GET /downloads/desktop/:version/:file" do
    it "redirects a published file to a presigned bucket URL (positive)" do
      allow(DesktopReleases).to receive(:client)
        .and_return(Aws::S3::Client.new(stub_responses: true, region: "garage", endpoint: "https://s3.test", force_path_style: true))
      seed_release("1.2.0", "Inbox2_1.2.0_x64-setup.exe" => "exe")

      get "/downloads/desktop/1.2.0/Inbox2_1.2.0_x64-setup.exe"

      expect(response).to have_http_status(:found)
      expect(response.location).to include("1.2.0/Inbox2_1.2.0_x64-setup.exe", "X-Amz-Signature")
    end

    it "404s a file that is not in the bucket (negative)" do
      get "/downloads/desktop/1.2.0/Inbox2.app.tar.gz"
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /api/v1/desktop/releases/latest" do
    it "lists per-OS installers including Linux (positive)" do
      seed_release(
        "2.0.0",
        "latest.json" => '{"version":"2.0.0","pub_date":"2026-06-24T00:00:00Z","platforms":{}}',
        "Inbox2_2.0.0_universal.dmg" => "dmg",
        "Inbox2_2.0.0_x64-setup.exe" => "exe",
        "Inbox2_2.0.0_amd64.AppImage" => "appimage",
        "Inbox2_2.0.0_amd64.deb" => "deb",
        "Inbox2_2.0.0_amd64.rpm" => "rpm",
        # updater artifacts + sigs must NOT appear as user downloads:
        "Inbox2.app.tar.gz" => "tar",
        "Inbox2_2.0.0_amd64.AppImage.sig" => "sig"
      )

      get "/api/v1/desktop/releases/latest"

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["version"]).to eq("2.0.0")

      oses = body["downloads"].map { |d| d["os"] }
      expect(oses).to include("macos", "windows", "linux")
      expect(oses).not_to include(nil)

      linux = body["downloads"].select { |d| d["os"] == "linux" }
      expect(linux.map { |d| d["kind"] }).to match_array(%w[appimage deb rpm])

      # No .sig / .app.tar.gz leaked as a download.
      filenames = body["downloads"].map { |d| d["filename"] }
      expect(filenames).not_to include("Inbox2.app.tar.gz")
      expect(filenames.none? { |f| f.end_with?(".sig") }).to be(true)

      # Absolute, public download URLs (not internal paths).
      expect(body["downloads"].first["url"]).to start_with("http")
    end

    it "204s when no build is published (negative)" do
      get "/api/v1/desktop/releases/latest"
      expect(response).to have_http_status(:no_content)
    end
  end
end
