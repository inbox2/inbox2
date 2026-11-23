module Api
  module V1
    class SignaturesController < BaseController
      before_action :require_organization!

      # spec 8.1.7, A13.2
      def index
        membership = current_active_membership!
        sigs = Signature.visible_to(membership).includes(:domain).order(:created_at).to_a
        # applied: the signature that goes under mail from each address this
        # member may send as, with {{name}}/{{email}} filled in. Clients look
        # the From address up here instead of choosing themselves.
        applied = membership.from_addresses.each_with_object({}) do |addr, out|
          sig = Signature.for_address(membership, addr, sigs)
          next unless sig

          html = sig.render_for(membership, addr)
          out[addr.downcase] = { id: sig.key, html: html, text: Signature.plain_text(html) }
        end
        render json: {
          signatures: sigs.map { |s| SignatureSerializer.new(s, params: { membership: membership }).to_h },
          applied: applied
        }
      end

      def create
        membership = current_active_membership!
        # shared: a domain or org-wide signature, which only an admin sets.
        shared = ActiveModel::Type::Boolean.new.cast(params[:shared])
        require_role!(*Membership::ADMIN_ROLES) if shared
        domain = params[:domain_id].present? ? current_organization.domains.find_by!(key: params[:domain_id]) : nil
        sig = current_organization.signatures.build(sig_params.merge(membership: shared ? nil : membership, domain: shared ? domain : nil))
        if sig.save
          render json: { signature: SignatureSerializer.new(sig, params: { membership: current_membership }).to_h }, status: :created
        else
          render json: ErrorSerializer.serialize(sig.errors.full_messages, status: 422), status: :unprocessable_content
        end
      end

      def update
        sig = find_writable_signature!
        return if performed?

        attrs = sig_params.to_h
        if !sig.personal? && params.key?(:domain_id)
          attrs[:domain] = params[:domain_id].present? ? current_organization.domains.find_by!(key: params[:domain_id]) : nil
        end
        if sig.update(attrs)
          render json: { signature: SignatureSerializer.new(sig, params: { membership: current_membership }).to_h }
        else
          render json: ErrorSerializer.serialize(sig.errors.full_messages, status: 422), status: :unprocessable_content
        end
      end

      def destroy
        sig = find_writable_signature!
        return if performed?

        sig.destroy!
        head :no_content
      end

      private

      # A member may only mutate their own personal signature. Org-wide
      # signatures (membership_id: nil) require admin. Scoping the personal
      # lookup to the caller's membership means a peer's signature key 404s
      # rather than being editable/deletable.
      def find_writable_signature!
        membership = current_active_membership!
        sig = current_organization.signatures.find_by!(key: params[:id])

        if sig.membership_id.nil?
          require_role!(*Membership::ADMIN_ROLES)
        elsif sig.membership_id != membership.id
          render json: ErrorSerializer.serialize("Signature not found", status: 404), status: :not_found
        end

        sig
      end

      def sig_params
        params.permit(:name, :body_html, :from_address, :is_default)
      end
    end
  end
end
