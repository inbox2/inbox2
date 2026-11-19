module Api
  module V1
    # Zero-knowledge cloud backup of external-mailbox channel credentials — see
    # docs/E2EE.md (credential vault). Per-user (personal mailboxes), so scoped to
    # current_user. The controller stores opaque ciphertext blobs verbatim and
    # NEVER decrypts: it holds no usable key. `provider` + `external_email` are the
    # only plaintext metadata (accepted leak, for the management UI).
    class StoredCredentialsController < BaseController
      # GET /api/v1/stored-credentials
      # Metadata list for the /console card and the client's "what's backed up?" check.
      # Never includes the blob (StoredCredentialSerializer omits it).
      def index
        creds = current_user.stored_credentials.order(:provider, :external_email)
        render json: {
          stored_credentials: creds.map { |c| StoredCredentialSerializer.new(c).to_h }
        }
      end

      # GET /api/v1/stored-credentials/:id
      # Restore fetch — returns the opaque ciphertext for one credential so the
      # device can decrypt it locally with the vault DEK.
      def show
        cred = current_user.stored_credentials.find_by_key!(params[:id])
        render json: { stored_credential: StoredCredentialBlobSerializer.new(cred).to_h }
      end

      # PUT /api/v1/stored-credentials
      # Idempotent upsert on (user, provider, external_email) — re-adding the same
      # account or a token refresh overwrites the blob (last-writer-wins).
      def upsert
        cred = current_user.stored_credentials.find_or_initialize_by(
          provider: params[:provider],
          external_email: params[:external_email]
        )
        cred.assign_attributes(cred_params)

        if cred.save
          render json: { stored_credential: StoredCredentialSerializer.new(cred).to_h },
            status: cred.previously_new_record? ? :created : :ok
        else
          render json: ErrorSerializer.serialize(cred.errors.full_messages, status: 422),
            status: :unprocessable_content
        end
      end

      # DELETE /api/v1/stored-credentials/:id
      # Removing a channel deletes its backup so it isn't restored on a new device.
      def destroy
        cred = current_user.stored_credentials.find_by_key!(params[:id])
        cred.destroy!
        head :no_content
      end

      # GET /api/v1/stored-credentials/vault
      # The wrapped DEK copies + Argon params a new device needs to unlock. Opaque.
      def vault
        v = current_user.credential_vault
        return head :not_found unless v

        render json: { vault: CredentialVaultSerializer.new(v).to_h }
      end

      # PUT /api/v1/stored-credentials/vault
      # Upsert the vault metadata (enable, or re-wrap after a password rotation).
      def upsert_vault
        v = current_user.credential_vault || current_user.build_credential_vault
        v.assign_attributes(vault_params)

        if v.save
          render json: { vault: CredentialVaultSerializer.new(v).to_h }
        else
          render json: ErrorSerializer.serialize(v.errors.full_messages, status: 422),
            status: :unprocessable_content
        end
      end

      # DELETE /api/v1/stored-credentials/vault
      # Turn off cloud backup: drop the vault and every stored credential under it.
      def destroy_vault
        current_user.stored_credentials.destroy_all
        current_user.credential_vault&.destroy!
        head :no_content
      end

      private

      def cred_params
        params.permit(:provider, :external_email, :blob, :blob_nonce, :blob_version)
      end

      def vault_params
        params.permit(:device_wrapped_dek, :passphrase_wrapped_dek, :argon_salt, argon_params: {})
      end
    end
  end
end
