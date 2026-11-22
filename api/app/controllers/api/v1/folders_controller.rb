module Api
  module V1
    # Address folders (AddressFolders): the tree for one domain, and the
    # member's own Show in Inbox / bell settings per folder.
    class FoldersController < BaseController
      before_action :require_organization!
      before_action :require_membership!

      # GET /api/v1/orgs/:org_id/folders?domain=dom_…
      def index
        domain = current_organization.domains.find_by(key: params[:domain])
        return not_found unless domain && current_membership.home_domain_ids.include?(domain.id)

        tree = AddressFolders.new(current_membership, domain).tree(visible_conversations)
        render json: { folders: tree.map { |f| FolderSerializer.new(Folder.new(**f)).to_h } }
      end

      # PATCH /api/v1/orgs/:org_id/folders/prefs  { address | "inbox", inbox?, notify? }
      def prefs
        key = params[:address].to_s.downcase
        return invalid("address is required") if key.blank?
        return invalid("not one of your folders") unless folder_key?(key)

        prefs = (current_membership.folder_prefs || {}).deep_dup
        entry = prefs.fetch(key, {})
        entry[AddressFolders::PREF_INBOX] = cast(params[:inbox]) if params.key?(:inbox) && key != AddressFolders::INBOX
        entry[AddressFolders::PREF_NOTIFY] = cast(params[:notify]) if params.key?(:notify)
        prefs[key] = entry
        current_membership.update!(folder_prefs: prefs)
        render json: { folder_prefs: prefs }
      end

      Folder = Struct.new(:key, :kind, :address, :parent, :unread, :can_reply, :in_inbox, :notify, keyword_init: true)

      private

      def require_membership!
        not_found unless current_membership
      end

      # "inbox" or an address on a domain this member works on (E3: never a
      # setting for another org's address).
      def folder_key?(key)
        return true if key == AddressFolders::INBOX

        host = key.split("@", 2)[1]
        current_organization.domains.where(id: current_membership.home_domain_ids).exists?(name: host)
      end

      def invalid(msg)
        render json: ErrorSerializer.serialize(msg, status: 422), status: :unprocessable_content
      end

      def cast(v) = ActiveModel::Type::Boolean.new.cast(v)
    end
  end
end
