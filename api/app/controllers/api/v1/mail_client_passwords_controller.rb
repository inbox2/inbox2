module Api
  module V1
    # A member's own app passwords for mail clients, and the settings to type
    # into one (docs/Mail-Clients.md).
    class MailClientPasswordsController < BaseController
      before_action :require_organization!
      before_action :require_enabled!, only: :create

      MAIL_HOST = "mx.#{DnsRecordsSerializer::MAIL_DOMAIN}".freeze

      def settings
        render json: { mail_client: {
          enabled: current_organization.mail_clients_open?,
          included_in_plan: current_organization.effective_plan.mail_clients?,
          addresses: current_active_membership!.email_addresses,
          imap: { host: MAIL_HOST, port: 993, security: "TLS" },
          smtp: { host: MAIL_HOST, port: 465, security: "TLS" }
        } }
      end

      def index
        passwords = current_active_membership!.mail_client_passwords.order(:id)
        render json: { passwords: passwords.map { |p| MailClientPasswordSerializer.new(p).to_h } }
      end

      # The password is shown once, here.
      def create
        password = current_active_membership!.mail_client_passwords.new(name: params[:name].to_s.strip)
        if password.save
          render json: { password: MailClientPasswordSerializer.new(password).to_h, token: password.raw_token }, status: :created
        else
          render json: ErrorSerializer.serialize(password.errors.full_messages, status: 422), status: :unprocessable_content
        end
      end

      def destroy
        current_active_membership!.mail_client_passwords.find_by!(key: params[:id]).destroy!
        head :no_content
      end

      private

      def require_enabled!
        return if current_organization.mail_clients_open?

        render json: ErrorSerializer.serialize("Mail clients are switched off for this organization", status: 403), status: :forbidden
      end
    end
  end
end
