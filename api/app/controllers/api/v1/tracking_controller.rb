module Api
  module V1
    # Open-tracking read-back for LOCAL channels (Gmail/Office365/IMAP), which
    # inject the pixel client-side and never store opens locally (the recipient's
    # mail client hits our server, not the device). The client polls here for
    # opens with the secrets behind the tokens it embedded. Reading is account-free
    # by design: iOS never signs into Rails (rails_jwt is empty). Inherits
    # ApplicationController, NOT BaseController.
    class TrackingController < ApplicationController
      MAX_TOKENS = 500

      # A custom host provisions a certificate on our Cloudflare account, so it takes a
      # linked inbox2 account (decided 2026-11-09). Reading opens stays account-free.
      before_action :authenticate_user!, only: %i[register verify_host]

      # POST /api/v1/tracking/opens  { secrets: ["..."], tokens: ["..."] }
      # → { opens: { "<token>": [ {opened_at, ip, geo_*, proxied, proxy_kind, user_agent}, ... ] } }
      #
      # A new pixel carries only the hash of a secret its device keeps, so a recipient
      # holding the token can't read the other recipients' opens. `tokens` serves
      # local-channel pixels from before that, and never an inbox2-hosted message's.
      def opens
        secrets = Array(params[:secrets]).map(&:to_s).reject(&:blank?).uniq.first(MAX_TOKENS)
        legacy = Array(params[:tokens]).map(&:to_s).select { |t| t.length == Tracking::LEGACY_TOKEN_LENGTH }.uniq.first(MAX_TOKENS)
        return render json: { opens: {} } if secrets.empty? && legacy.empty?

        grouped = MessageOpen.where(token: secrets.map { |s| Tracking.token_for(s) })
          .or(MessageOpen.where(token: legacy, organization_id: nil))
          .order(opened_at: :asc).group_by(&:token)
        result = grouped.transform_values do |opens|
          opens.map { |o| MessageOpenSerializer.new(o).to_h }
        end

        render json: { opens: result }
      end

      # POST /api/v1/tracking/register  { host: "track.tuli.com" }
      # A local channel opts into a custom tracking host — a subdomain of ITS OWN
      # sending domain keeps the pixel same-domain as the From address (lower spam
      # scoring than the shared inbox2 host). Provisions the Cloudflare-for-SaaS
      # custom hostname (idempotent) so TLS issues once the customer's DNS-only
      # CNAME points at us.
      def register
        host = normalize_host
        return render json: { error: "host required" }, status: :unprocessable_content if host.blank?

        cf_id = begin
          CloudflareCustomHostname.new.ensure(host)
        rescue CloudflareCustomHostname::Error => e
          Rails.logger.warn("[TrackingController] CF ensure #{host} failed: #{e.message}")
          nil
        end

        render json: host_payload(host, cf_id: cf_id)
      end

      # POST /api/v1/tracking/verify-host  { host: }
      def verify_host
        host = normalize_host
        return render json: { error: "host required" }, status: :unprocessable_content if host.blank?

        dns = TrackingDns.verify_host(host)
        cf_id = (CloudflareCustomHostname.new.ensure(host) rescue nil)
        cert = CloudflareCustomHostname.new.status(cf_id)
        verified = dns[:ok] && (cert[:active] || !CloudflareCustomHostname.enabled?)

        render json: host_payload(host, cf_id: cf_id, dns: dns, cert: cert, verified: verified)
      end

      private

      def normalize_host
        params[:host].to_s.downcase.strip.presence
      end

      def host_payload(host, cf_id: nil, dns: nil, cert: nil, verified: nil)
        {
          host: host,
          cname_target: Tracking::DEFAULT_HOST,
          records: TrackingDns.required_records(host),
          cloudflare_saas: CloudflareCustomHostname.enabled?,
          cf_hostname_id: cf_id,
          dns: dns,
          cert: cert,
          verified: verified
        }.compact
      end
    end
  end
end
