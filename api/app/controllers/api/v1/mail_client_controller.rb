module Api
  module V1
    # What the IMAP and SMTP frontend (mta/cmd/imap) calls, on behalf of one
    # signed-in person (docs/Mail-Clients.md has the contract). Every request
    # carries that person's login and app password, so this can never serve
    # more than their own mail.
    class MailClientController < ApplicationController
      before_action :sign_in!
      rescue_from(::MailClient::Refused) { |e| render json: ErrorSerializer.serialize(e.message, status: e.status), status: e.status }

      def session_info
        render json: { login: @login, name: @membership.user.display_name.presence || @membership.user.username }
      end

      def folders
        render json: { folders: mailbox.folders }
      end

      def messages
        render json: mailbox.list(params[:folder])
      end

      def header
        send_data ::MailClient::Mime.new(row.message).header, type: "message/rfc822", disposition: "inline"
      end

      def raw
        found = row
        bytes = ::MailClient::Mime.new(found.message).raw
        # The listed size is computed without the attachments; if storage holds
        # something else, the truth wins from here on.
        found.update_column(:size, bytes.bytesize) if found.size != bytes.bytesize
        send_data bytes, type: "message/rfc822", disposition: "inline"
      end

      def flags
        render json: { messages: mailbox.store_flags(params[:folder], uids, params[:mode].to_s, Array(params[:flags])) }
      end

      def move
        render json: { moved: mailbox.move(params[:folder], uids, params[:to].to_s) }
      end

      def expunge
        render json: { expunged: mailbox.expunge(params[:folder], uids.presence) }
      end

      def search
        render json: { uids: mailbox.search(params[:folder], params.permit(:from, :to, :subject, :text, :since, :before)) }
      end

      def append
        render json: { uid: mailbox.append(params[:folder], Base64.decode64(params[:raw_b64].to_s)) }
      end

      def submit
        message = ::MailClient::Submit.new(@membership, mail_from: params[:mail_from], rcpt_to: params[:rcpt_to],
          raw: Base64.decode64(params[:raw_b64].to_s)).call
        render json: { id: message.key }
      end

      private

      def mailbox = @mailbox ||= ::MailClient::Mailbox.new(@membership)
      def row = mailbox.find(params[:folder], params[:uid])
      def uids = Array(params[:uids]).map(&:to_i)

      def sign_in!
        login, password = ActionController::HttpAuthentication::Basic.user_name_and_password(request) if request.authorization.to_s.start_with?("Basic ")
        membership = MailClientPassword.authenticate(password)&.membership
        @login = login.to_s.strip.downcase
        unless membership&.status == Membership::STATUS_ACTIVE && membership.email_addresses.map(&:downcase).include?(@login)
          return render json: ErrorSerializer.serialize("Unauthorized", status: 401), status: :unauthorized
        end

        org = membership.organization
        return forbid("Mail clients are switched off for this organization") unless org.mail_clients_open?
        if (domain = org.domains.find_by(name: @login.split("@").last)) && domain.e2ee_enabled
          return forbid("#{domain.name} is a sealed domain; its mail opens only in inbox2 apps")
        end

        @membership = membership
      end

      def forbid(message)
        render json: ErrorSerializer.serialize(message, status: 403), status: :forbidden
      end
    end
  end
end
