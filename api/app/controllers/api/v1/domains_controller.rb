module Api
  module V1
    # Domains owned by an organization (first-class). DNS verify/records live here
    # (per domain). Domain creation is gated by the org's domains-per-plan quota.
    class DomainsController < BaseController
      include ImageAssets

      # `brand` streams a public image into <img> tags — no bearer token.
      skip_before_action :authenticate_user!, only: :brand
      before_action :require_organization!, except: :brand
      before_action -> { require_role!(*Membership::ADMIN_ROLES) }, except: %i[index show dns brand]
      before_action :set_domain, only: %i[show destroy dns verify upload_icon configure_cloudflare
                                           tracking update_tracking verify_tracking]

      def index
        domains = OrganizationSerializer.visible_domains(current_organization, current_membership)
        render json: { domains: domains.map { |d| DomainSerializer.new(d).to_h } }
      end

      def show
        render json: { domain: DomainSerializer.new(@domain).to_h }
      end

      def create
        if current_organization.domain_limit_reached?
          return render json: ErrorSerializer.serialize("Domain limit reached for this plan", status: 403), status: :forbidden
        end

        name = params[:domain].to_s.downcase.strip
        first_domain = current_organization.domains.empty?
        domain = current_organization.domains.build(name: name, status: Domain::STATUS_PENDING_DNS)
        if domain.save
          # The first domain becomes the org's default (branding source) — fetch its
          # favicon for the org. A later domain shows its initial until someone
          # uploads an icon: fetched favicons (og:image screenshots included) made
          # the channel chips unrecognisable (reverted 2026-11-19).
          FetchFaviconJob.perform_later(current_organization.id) if first_domain
          render json: { domain: DomainSerializer.new(domain).to_h }, status: :created
        else
          render json: ErrorSerializer.serialize(domain.errors.full_messages, status: 422), status: :unprocessable_content
        end
      end

      def destroy
        # All domains are equal (no primary), so any can be removed freely; the
        # org's default domain simply re-derives to the next-oldest.
        @domain.destroy!
        head :no_content
      end

      # spec 2.3.2 — required DNS records for this domain. `provider` is a best-
      # effort NS-based detection ("cloudflare") that unlocks the one-click
      # auto-configure path in the setup UI.
      def dns
        render json: DnsRecordsSerializer.new(@domain).to_h.merge(provider: dns_provider)
      end

      # spec A3.6 — live DNS check for this domain
      def verify
        result = DnsChecker.new(@domain).call
        @domain.record_dns_check!(result)
        render json: { status: @domain.status, verified: result[:mx_ok], checks: result[:checks] }
      end

      # POST /orgs/:org_id/domains/:id/dns/cloudflare — write the required records
      # into the domain's Cloudflare zone with a customer-supplied API token, then
      # re-verify. The token is used transiently (never stored). Admin/owner only.
      def configure_cloudflare
        token = params[:token].to_s.strip
        if token.blank?
          return render json: ErrorSerializer.serialize("A Cloudflare API token is required", status: 422), status: :unprocessable_content
        end

        applied = CloudflareDns.new(token).apply(@domain)
        result = DnsChecker.new(@domain).call
        @domain.record_dns_check!(result)
        render json: { applied: applied, status: @domain.status, verified: result[:mx_ok], checks: result[:checks] }
      rescue CloudflareDns::Error => e
        render json: ErrorSerializer.serialize(e.message, status: 422), status: :unprocessable_content
      end

      # GET /orgs/:org_id/domains/:id/tracking — open-tracking settings + the DNS
      # records/cert status for a custom tracking host (docs/Open-Tracking.md).
      def tracking
        render json: tracking_payload
      end

      # PATCH .../tracking — toggle open tracking + set/clear the custom tracking
      # host. Changing the host resets verification and (re)provisions the
      # Cloudflare-for-SaaS custom hostname that terminates TLS for it.
      def update_tracking
        attrs = {}
        unless params[:open_tracking_enabled].nil?
          attrs[:open_tracking_enabled] = ActiveModel::Type::Boolean.new.cast(params[:open_tracking_enabled])
        end
        unless params[:link_tracking_enabled].nil?
          attrs[:link_tracking_enabled] = ActiveModel::Type::Boolean.new.cast(params[:link_tracking_enabled])
        end

        if params.key?(:tracking_domain)
          new_host = params[:tracking_domain].to_s.downcase.strip.presence
          if new_host != @domain.tracking_domain
            deprovision_tracking_hostname
            attrs[:tracking_domain] = new_host
            attrs[:tracking_domain_verified_at] = nil
            attrs[:tracking_cf_hostname_id] = nil
          end
        end

        @domain.update!(attrs) if attrs.any?

        # Provision a CF custom hostname for a new custom host so its cert issues
        # as soon as the customer's DNS-only CNAME points at us.
        if @domain.tracking_domain.present? && @domain.tracking_cf_hostname_id.blank?
          if (id = CloudflareCustomHostname.new.ensure(@domain.tracking_domain))
            @domain.update!(tracking_cf_hostname_id: id)
          end
        end

        render json: tracking_payload
      rescue CloudflareCustomHostname::Error => e
        render json: ErrorSerializer.serialize(e.message, status: 422), status: :unprocessable_content
      end

      # POST .../tracking/verify — check the custom host's CNAME (incl. the
      # Cloudflare orange-cloud conflict) + the CF cert, and mark it verified.
      def verify_tracking
        dns = TrackingDns.new(@domain).call
        cert = CloudflareCustomHostname.new.status(@domain.tracking_cf_hostname_id)

        # Verified once DNS is right AND the cert is active (or CF-for-SaaS isn't
        # configured on this deployment, in which case DNS alone is the gate).
        verified = @domain.tracking_domain.blank? ||
                   (dns[:ok] && (cert[:active] || !CloudflareCustomHostname.enabled?))
        @domain.update!(tracking_domain_verified_at: verified ? Time.current : nil)

        render json: tracking_payload(dns: dns, cert: cert)
      end

      # POST /orgs/:org_id/domains/:id/icon — upload this domain's square icon.
      # Mirrors OrganizationsController#upload_icon but stores per-domain. The
      # bytes are sniffed (not trusted from the client) via ImageAssets.
      def upload_icon
        file = params[:file]
        content_type = validate_image_upload!(file, label: "Icon")
        return unless content_type

        storage_key = storage_service.upload(
          file.read,
          filename: file.original_filename,
          content_type: content_type,
          organization_key: current_organization.key
        )
        @domain.update!(icon_url: storage_key)
        render json: { domain: DomainSerializer.new(@domain).to_h }
      rescue Aws::Errors::ServiceError, Seahorse::Client::NetworkingError, KeyError => e
        Rails.logger.error("[DomainsController] Icon upload failed: #{e.class}: #{e.message}")
        render json: ErrorSerializer.serialize("Storage service unavailable — try again shortly", status: 503), status: :service_unavailable
      end

      # GET /orgs/:org_id/domains/:id/brand/icon — public. Streams the domain's
      # stored icon so it loads in plain <img> tags (workspace tab). Resolves the
      # org + domain from the path (no authed context on this public route).
      def brand
        org = Organization.find_by(key: params[:org_id])
        domain = org&.domains&.find_by(key: params[:id])
        return head :not_found if domain&.icon_url.blank?

        bytes, content_type = storage_service.download_with_type(domain.icon_url)
        expires_in 1.day, public: true
        send_image_asset(bytes, content_type)
      rescue Aws::S3::Errors::NoSuchKey
        head :not_found
      rescue Aws::Errors::ServiceError, Seahorse::Client::NetworkingError, KeyError => e
        Rails.logger.error("[DomainsController] brand fetch failed: #{e.class}: #{e.message}")
        head :service_unavailable
      end

      private

      def set_domain
        @domain = current_organization.domains.find_by!(key: params[:id])
        # A domain-scoped member gets a 404 for the org's other domains (E3).
        raise ActiveRecord::RecordNotFound if current_membership && !current_membership.home_domain_ids.include?(@domain.id)
      end

      # Best-effort DNS provider detection from the domain's nameservers, so the
      # setup UI can offer a one-click auto-configure path. Only Cloudflare today.
      def dns_provider
        ns = DnsResolver.new.ns(@domain.name)
        "cloudflare" if ns.any? { |h| h.end_with?("ns.cloudflare.com") }
      rescue StandardError
        nil
      end

      def storage_service
        @storage_service ||= S3StorageService.new
      end

      def tracking_payload(dns: nil, cert: nil)
        host = @domain.tracking_domain
        {
          open_tracking_enabled: @domain.open_tracking_enabled,
          link_tracking_enabled: @domain.link_tracking_enabled,
          tracking_domain: host,
          tracking_host: @domain.tracking_host,        # what actually gets used at send
          default_host: Tracking::DEFAULT_HOST,
          verified: @domain.tracking_domain_verified_at.present?,
          records: host.present? ? TrackingDns.required_records(host) : [],
          cloudflare_saas: CloudflareCustomHostname.enabled?,
          dns: dns,
          cert: cert
        }
      end

      def deprovision_tracking_hostname
        return if @domain.tracking_cf_hostname_id.blank?
        CloudflareCustomHostname.new.delete(@domain.tracking_cf_hostname_id)
      end
    end
  end
end
