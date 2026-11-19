module Api
  module V1
    class SignaturesController < BaseController
      before_action :require_organization!

      # spec 8.1.7, A13.2
      def index
        membership = current_active_membership!
        sigs = current_organization.signatures.org_wide
          .or(current_organization.signatures.personal_for(membership))
        render json: { signatures: sigs.map { |s| SignatureSerializer.new(s).to_h } }
      end

      def create
        membership = current_active_membership!
        sig = current_organization.signatures.build(sig_params.merge(membership: membership))
        if sig.save
          render json: { signature: SignatureSerializer.new(sig).to_h }, status: :created
        else
          render json: ErrorSerializer.serialize(sig.errors.full_messages, status: 422), status: :unprocessable_content
        end
      end

      def update
        sig = find_writable_signature!
        return if performed?

        if sig.update(sig_params)
          render json: { signature: SignatureSerializer.new(sig).to_h }
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
