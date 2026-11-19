require "rails_helper"

RSpec.describe "Api::V1::Weather", type: :request do
  # Feeds the Bridge morning brief. Public + unauthenticated; always 200.
  describe "GET /api/v1/weather" do
    it "returns a spoken weather line for a geolocatable IP" do
      result = WeatherService::Result.new(
        short: "Currently 14°C and cloudy in Amsterdam.", temp_c: 14, code: 3, place: "Amsterdam"
      )
      allow(WeatherService).to receive(:for_ip).and_return(result)

      get "/api/v1/weather"

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["short"]).to eq("Currently 14°C and cloudy in Amsterdam.")
      expect(body["temp_c"]).to eq(14)
      expect(body["code"]).to eq(3)
      expect(body["place"]).to eq("Amsterdam")
    end

    it "requires no authentication" do
      allow(WeatherService).to receive(:for_ip).and_return(nil)

      get "/api/v1/weather"

      expect(response).to have_http_status(:ok)
    end

    it "returns 200 with null short when weather is unavailable (upstream failure)" do
      allow(WeatherService).to receive(:for_ip).and_return(nil)

      get "/api/v1/weather"

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["short"]).to be_nil
      expect(body).to have_key("temp_c")
    end
  end

  describe WeatherService do
    it "builds a short line and maps the weather code" do
      service = described_class.new("8.8.8.8")
      allow(service).to receive(:geolocate).and_return(lat: 52.37, lon: 4.89, place: "Amsterdam")
      allow(service).to receive(:current_weather).with(52.37, 4.89).and_return(temp_c: 14, code: 3)

      result = service.call
      expect(result.short).to eq("Currently 14°C and cloudy in Amsterdam.")
      expect(result.code).to eq(3)
    end

    it "returns nil when the IP can't be geolocated" do
      service = described_class.new("127.0.0.1")
      allow(service).to receive(:geolocate).and_return(nil)

      expect(service.call).to be_nil
    end

    it "omits condition and place gracefully when unknown" do
      service = described_class.new("8.8.8.8")
      allow(service).to receive(:geolocate).and_return(lat: 1.0, lon: 2.0, place: nil)
      allow(service).to receive(:current_weather).and_return(temp_c: 20, code: 999)

      expect(service.call.short).to eq("Currently 20°C.")
    end
  end
end
