module Api
  module V1
    # Image proxy — fetches remote images server-side so the reader's IP, User-Agent
    # and open-time are never exposed to the sender (email tracking-pixel defence,
    # spec 4.1.2). User-scoped via the standard bearer token (web session or API
    # key), like push subscriptions. The client loads images with fetch() so the
    # token rides in the Authorization header, never in the URL.
    #
    # Returns raw image bytes, not JSON — a deliberate exception to E2/Alba, the
    # same as the raw-message endpoint. SSRF is guarded by PrivateAddressGuard on
    # the initial URL and every redirect hop.
    class ImageProxyController < BaseController
      MAX_BYTES = 10 * 1024 * 1024
      MAX_REDIRECTS = 3
      OPEN_TIMEOUT = 2
      READ_TIMEOUT = 3
      TOTAL_TIMEOUT = 5 # one slow image must not hold a Puma thread, redirects and body included
      # Versioned UA with the public bot page, per Cloudflare's Verified Bots
      # policy (distinct, documented agent). The page documents purpose, this UA,
      # and the Web Bot Auth key directory.
      USER_AGENT = "inbox2-image-proxy/1.0 (+https://inbox2.com/bot)".freeze

      # GET /api/v1/image-proxy?url=<encoded>
      def show
        url = params.require(:url)
        return reject unless PrivateAddressGuard.public_url?(url)

        result = Timeout.timeout(TOTAL_TIMEOUT, Net::ReadTimeout) { fetch_with_redirects(url) }

        case result
        when :blocked, :too_many_redirects
          reject
        when :too_large
          too_large_response
        when Net::HTTPSuccess
          deliver(result)
        else
          render json: ErrorSerializer.serialize("Upstream fetch failed", status: 502), status: :bad_gateway
        end
      rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, Errno::ECONNREFUSED, OpenSSL::SSL::SSLError => e
        Rails.logger.warn("[ImageProxy] #{e.class}: #{e.message}")
        render json: ErrorSerializer.serialize("Upstream fetch failed", status: 502), status: :bad_gateway
      end

      private

      def deliver(response)
        content_type = response["Content-Type"].to_s.split(";").first&.strip
        unless content_type&.start_with?("image/")
          return render json: ErrorSerializer.serialize("Not an image", status: 415),
                        status: :unsupported_media_type
        end

        return too_large_response if response["Content-Length"].to_i > MAX_BYTES

        body = response.body.to_s
        return too_large_response if body.bytesize > MAX_BYTES

        expires_in 1.day, public: false
        send_data body, type: content_type, disposition: "inline"
      end

      def too_large_response
        render json: ErrorSerializer.serialize("Image too large", status: 413), status: :content_too_large
      end

      def reject
        render json: ErrorSerializer.serialize("URL not allowed", status: 422), status: :unprocessable_content
      end

      def fetch_with_redirects(url, redirects_left = MAX_REDIRECTS)
        # Resolve + validate ONCE here and pin the socket to that IP (below), so a
        # DNS-rebinding answer can't swap in a private address between this check
        # and the connect. Re-done per redirect hop.
        pinned = PrivateAddressGuard.pinned_url(url)
        return :blocked unless pinned

        uri, ip = pinned
        response = perform_get(uri, ip)

        return response unless response.is_a?(Net::HTTPRedirection)
        return :too_many_redirects if redirects_left <= 0

        location = response["Location"]
        target = location && URI.join(uri.to_s, location).to_s
        return :blocked unless target

        fetch_with_redirects(target, redirects_left - 1)
      end

      # Seam for stubbing in specs.
      def perform_get(uri, pinned_ip = nil)
        http = Net::HTTP.new(uri.host, uri.port)
        # Pin to the pre-validated IP; SNI + Host header stay uri.host.
        http.ipaddr = pinned_ip if pinned_ip
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = OPEN_TIMEOUT
        http.read_timeout = READ_TIMEOUT

        request = Net::HTTP::Get.new(uri)
        request["User-Agent"] = USER_AGENT
        request["Accept"] = "image/*"
        # Web Bot Auth (RFC 9421) — lets bot-managed CDNs verify us instead of
        # 403ing by TLS fingerprint. Signed per hop (the signature binds
        # @authority). No-op until WEB_BOT_AUTH_KEY is configured.
        WebBotAuth.sign!(request, authority: WebBotAuth.authority_for(uri))
        http.request(request)
      end
    end
  end
end
