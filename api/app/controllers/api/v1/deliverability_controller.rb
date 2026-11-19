module Api
  module V1
    # Per-org (= per-domain, in the console's model) outbound deliverability:
    # choose inbox2's built-in SMTP or point outbound mail at a customer-owned ESP
    # (SES / SendGrid / Mailgun / Postmark / Messy / custom SMTP). Backs the
    # "Deliverability" tab on the console's domain settings screen.
    class DeliverabilityController < BaseController
      before_action :require_organization!

      # GET /orgs/:org_id/deliverability/auth-reports — received TLS-RPT + DMARC
      # rua aggregates (TODO 46.10): how receiving providers judged our mail's
      # auth/TLS, newest first. failures_only=1 narrows to reports with failures.
      def auth_reports
        require_role!(*Membership::ADMIN_ROLES)

        reports = current_organization.mail_auth_reports.recent.limit(100)
        reports = reports.with_failures if params[:failures_only].present?
        render json: { auth_reports: reports.map { |r| MailAuthReportSerializer.new(r).to_h } }
      end

      # GET /orgs/:org_id/deliverability — current mode + redacted config + the
      # provider catalog the picker is built from.
      def show
        DeliveryChannel.ensure_builtin(current_organization)
        render json: { deliverability: DeliverabilitySerializer.new(current_organization).to_h }
      end

      # PUT /orgs/:org_id/deliverability — switch to built-in, or upsert + activate
      # a custom provider channel.
      def update
        require_role!(*Membership::ADMIN_ROLES)

        if params[:mode].to_s == DeliveryChannel::KIND_BUILTIN || params[:mode].to_s == "builtin"
          switch_to_builtin!
        else
          kind = params[:kind].to_s
          unless DeliveryChannel::CUSTOM_KINDS.include?(kind)
            return render json: ErrorSerializer.serialize("Unknown provider: #{kind}", status: 422), status: :unprocessable_content
          end

          channel = activate_custom!(kind)
          unless channel.persisted? && channel.errors.empty?
            return render json: ErrorSerializer.serialize(channel.errors.full_messages, status: 422), status: :unprocessable_content
          end
        end

        render json: { deliverability: DeliverabilitySerializer.new(current_organization).to_h }
      end

      # POST /orgs/:org_id/deliverability/test — pre-flight a provider's
      # credentials without sending. Posted secrets fall back to the saved ones.
      def test
        require_role!(*Membership::ADMIN_ROLES)

        kind = params[:kind].to_s
        if kind.blank? || kind == DeliveryChannel::KIND_BUILTIN
          return render json: { status: "ok", message: "inbox2 deliverability is always available." }
        end
        unless DeliveryChannel::CUSTOM_KINDS.include?(kind)
          return render json: ErrorSerializer.serialize("Unknown provider: #{kind}", status: 422), status: :unprocessable_content
        end

        existing = current_organization.delivery_channels.find_by(kind: kind)
        transient = DeliveryChannel.new(
          organization: current_organization,
          kind: kind,
          name: DeliveryProviders.label_for(kind),
          config: merged_config(existing, kind)
        )
        result = DeliveryProviders.for(transient).verify

        if result.accepted?
          render json: { status: "ok", message: "#{DeliveryProviders.label_for(kind)} connection looks good." }
        else
          render json: { status: "error", message: result.error.presence || "Connection failed." }
        end
      end

      private

      def switch_to_builtin!
        builtin = DeliveryChannel.ensure_builtin(current_organization)
        current_organization.delivery_channels.where.not(id: builtin.id).update_all(is_default: false)
        builtin.update!(is_default: true, status: DeliveryChannel::STATUS_ACTIVE)
      end

      def activate_custom!(kind)
        channel = current_organization.delivery_channels.find_or_initialize_by(kind: kind)
        channel.name = DeliveryProviders.label_for(kind)
        channel.config = merged_config(channel, kind)
        channel.status = DeliveryChannel::STATUS_ACTIVE
        channel.is_default = true
        return channel unless channel.save

        current_organization.delivery_channels.where.not(id: channel.id).update_all(is_default: false)
        channel
      end

      # Merge the posted config over what's saved, dropping blank secret fields so
      # an untouched password/key keeps its stored value. Only known fields for the
      # kind are kept.
      def merged_config(channel, kind)
        existing = (channel&.config || {}).with_indifferent_access
        incoming = config_params(kind)
        secrets = DeliveryProviders.secret_fields(kind)
        incoming.reject! { |k, v| secrets.include?(k) && v.to_s.blank? }
        existing.merge(incoming).to_h
      end

      def config_params(kind)
        params.fetch(:config, {}).permit(*DeliveryProviders.field_keys(kind)).to_h
      rescue ActionController::UnpermittedParameters, NoMethodError
        {}
      end
    end
  end
end
