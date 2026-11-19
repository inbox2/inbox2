require "ipaddr"

module Api
  module V1
    module Saas
      # Base for the platform SaaS surface. Deliberately bypasses the
      # tenant-scoping that Api::V1::BaseController enforces (E3) — operators act
      # across ALL orgs/users — so it does NOT inherit it. The gate is instead:
      #
      #   1. IP allowlist        (SAAS_IP_ALLOWLIST, CIDR list)
      #   2. mTLS client cert    (verified at the ingress, passed via headers,
      #                           matched to an AdminCredential by fingerprint)
      #
      # There is no bearer/user auth here. See docs/SaaS.md.
      class BaseController < ApplicationController
        include Paginatable

        before_action :enforce_ip_allowlist!
        before_action :authenticate_saas!

        private

        attr_reader :current_admin

        # ── IP allowlist ──────────────────────────────────────────────────────
        def enforce_ip_allowlist!
          return if ip_allowed?(client_ip)

          render_error("Forbidden", status: :forbidden)
        end

        def ip_allowed?(ip)
          ranges = saas_ip_ranges
          return true if ranges.empty? # unset = allow (dev). Production MUST set it.

          addr = IPAddr.new(ip) rescue nil
          return false unless addr

          ranges.any? { |range| range.include?(addr) }
        end

        def saas_ip_ranges
          @saas_ip_ranges ||= ENV.fetch("SAAS_IP_ALLOWLIST", "")
            .split(",").map(&:strip).reject(&:blank?)
            .filter_map { |cidr| IPAddr.new(cidr) rescue nil }
        end

        # ── Client-cert authentication ────────────────────────────────────────
        def authenticate_saas!
          @current_admin = AdminCredential.authenticate(client_cert_fingerprint)
          return render_error("SaaS authentication required", status: :unauthorized) unless @current_admin

          @current_admin.touch_usage!(client_ip)
        end

        # The verified client-cert fingerprint, as stamped by the mTLS-terminating
        # ingress (ssl-client-verify must be SUCCESS). The ingress is responsible
        # for stripping any client-supplied copies of these headers.
        #
        # Trusting the headers is OPT-IN in every environment (SAAS_ALLOW_HEADER_AUTH):
        # production used to trust them unconditionally, so until the ingress
        # actually does mTLS, anyone on the internet could present the headers
        # themselves and the fingerprint was a bare bearer secret. Unset = the
        # operator plane is closed. Set it only together with SAAS_IP_ALLOWLIST
        # (+ TRUSTED_PROXIES so the allowlist sees the real client) or real
        # ingress mTLS. See docs/SaaS.md.
        def client_cert_fingerprint
          return nil unless header_auth_trusted?
          return nil unless request.headers["ssl-client-verify"].to_s.upcase == "SUCCESS"

          request.headers["ssl-client-fingerprint"].presence
        end

        def header_auth_trusted?
          ActiveModel::Type::Boolean.new.cast(ENV["SAAS_ALLOW_HEADER_AUTH"])
        end

        def client_ip
          request.remote_ip
        end

        # ── Audit ─────────────────────────────────────────────────────────────
        def audit!(action, target: nil, metadata: {})
          SaasAuditLog.record!(
            admin: current_admin, action: action, target: target,
            ip: client_ip, metadata: metadata
          )
        end

        # ── Shared helpers ────────────────────────────────────────────────────
        def render_error(messages, status:)
          render json: ErrorSerializer.serialize(messages, status: Rack::Utils.status_code(status)), status: status
        end

        # `paginate` comes from Paginatable (shared with Api::V1::BaseController).
      end
    end
  end
end
