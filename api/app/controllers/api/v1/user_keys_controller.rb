module Api
  module V1
    # The current user's E2EE identity keypair (docs/E2EE.md Phase B). The server
    # is a blob store: it holds the public key plus the private key wrapped under
    # the password-KEK and under the recovery passphrase, and can unwrap neither.
    # There is deliberately no cross-user endpoint — other members' PUBLIC keys
    # are exposed via the domain e2ee directory, wrapped blobs only ever to self.
    class UserKeysController < BaseController
      def show
        user_key = current_user.user_key
        return render json: ErrorSerializer.serialize("No identity key", status: 404), status: :not_found unless user_key

        render json: { user_key: UserKeySerializer.new(user_key).to_h }
      end

      def upsert
        user_key = current_user.user_key || current_user.build_user_key

        # Recovery re-wraps the key under the account password. A client that
        # sends that password has it checked here, so the key can never end up
        # under a mistyped one (which would lock the account password out again).
        if params.key?(:current_password) && !current_user.authenticate(params[:current_password].to_s)
          return render json: ErrorSerializer.serialize("Current password is incorrect", status: 422), status: :unprocessable_content
        end

        # Replacing the public key is a new identity: existing domain-key grants
        # (sealed to the old key) become unopenable by it. Allowed — the recovery
        # flow re-wraps (same public key), and a genuine identity reset expects
        # re-grants — but never silently: the client must say so.
        replacing = user_key.persisted? && user_key.public_key != params[:public_key].to_s
        if replacing && !ActiveModel::Type::Boolean.new.cast(params[:replace_identity])
          return render json: ErrorSerializer.serialize(
            "public_key differs from the existing identity; pass replace_identity=true to replace it (existing grants will need re-issuing)",
            status: 409
          ), status: :conflict
        end

        # A new identity means every future sealed message is sealed to the NEW
        # key: a stolen session must not be enough to swap it. The password check
        # above only runs when the client volunteers one — for a replacement it
        # is mandatory.
        if replacing && !params.key?(:current_password)
          return render json: ErrorSerializer.serialize("current_password is required to replace the identity key", status: 401), status: :unauthorized
        end

        user_key.assign_attributes(
          public_key: params[:public_key],
          encrypted_private_key: params[:encrypted_private_key],
          recovery_encrypted_private_key: params[:recovery_encrypted_private_key],
          kdf_params: params[:kdf_params].respond_to?(:to_unsafe_h) ? params[:kdf_params].to_unsafe_h : (params[:kdf_params] || {})
        )

        if user_key.save
          render json: { user_key: UserKeySerializer.new(user_key).to_h }
        else
          render json: ErrorSerializer.serialize(user_key.errors.full_messages, status: 422), status: :unprocessable_content
        end
      end

      # Emails the user their passphrase-wrapped recovery file as a portable
      # offsite backup (docs/E2EE.md "Key loss & recovery", Option A). The blob
      # is client-produced opaque ciphertext — the passphrase and plaintext key
      # never touch the server, Messy, or the mailbox; the file is useless
      # without the passphrase.
      MAX_RECOVERY_BLOB_BYTES = 64 * 1024

      def send_recovery_email
        blob = params[:blob].to_s
        if blob.blank? || blob.bytesize > MAX_RECOVERY_BLOB_BYTES
          return render json: ErrorSerializer.serialize("blob required (max #{MAX_RECOVERY_BLOB_BYTES} bytes)", status: 422), status: :unprocessable_content
        end

        to = current_user.billing_email.presence
        unless to
          return render json: ErrorSerializer.serialize("No email address on the account", status: 422), status: :unprocessable_content
        end

        body = ApplicationController.renderer.render(
          template: "e2ee_mailer/recovery_backup",
          formats: [:html],
          layout: false,
          locals: { username: current_user.username, blob: blob, generated_at: Time.current }
        )
        MessyTriggerJob.perform_later(
          "send_message",
          to: to,
          subject: "Your inbox2 encryption recovery file — keep this safe",
          body: body
        )
        head :accepted
      end
    end
  end
end
