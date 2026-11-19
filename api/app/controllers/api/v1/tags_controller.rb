module Api
  module V1
    # Team tags (admins make them) and private labels (any member makes their
    # own; only they see or change them — docs/plans/mail-import.md D11/D12).
    class TagsController < BaseController
      before_action :require_organization!

      # spec 6.2.1, A9.1 — the team's tags and the member's own labels.
      def index
        # Lazily backfill system tags (Urgent/Important/Later) for orgs created
        # before a given system tag existed, so the priority client can always
        # find them. Idempotent — find_or_create_by.
        Tag.ensure_system_tags(current_organization)
        tags = current_organization.tags.visible_to(current_membership).order(:name)
        render json: { tags: tags.map { |t| TagSerializer.new(t).to_h } }
      end

      # spec 6.2.1, A9.1 — { name, color, private }. A private label needs only
      # membership; a team tag needs an owner or admin.
      def create
        private_label = ActiveModel::Type::Boolean.new.cast(params[:private])
        if private_label
          return forbidden unless current_membership
        else
          require_role!(*Membership::ADMIN_ROLES)
        end

        tag = current_organization.tags.build(tag_params.merge(membership: private_label ? current_membership : nil))

        if tag.save
          render json: { tag: TagSerializer.new(tag).to_h }, status: :created
        else
          render json: ErrorSerializer.serialize(tag.errors.full_messages, status: 422), status: :unprocessable_content
        end
      end

      # spec 6.2.1, A9.1
      def update
        tag = editable_tag or return

        if tag.update(tag_params)
          render json: { tag: TagSerializer.new(tag).to_h }
        else
          render json: ErrorSerializer.serialize(tag.errors.full_messages, status: 422), status: :unprocessable_content
        end
      end

      # spec 6.2.1, A9.1
      def destroy
        tag = editable_tag or return

        if tag.system?
          render json: ErrorSerializer.serialize(["System tags cannot be deleted"], status: 422), status: :unprocessable_content
          return
        end

        tag.destroy!
        head :no_content
      end

      # POST /tags/:id/share — the owner turns their private label into a team
      # tag, with every conversation it is on. Team tags are admin-made, so the
      # owner must be an owner or admin too.
      def share
        tag = current_organization.tags.where(membership: current_membership).find_by!(key: params[:id])
        require_role!(*Membership::ADMIN_ROLES)

        if tag.update(membership: nil)
          render json: { tag: TagSerializer.new(tag).to_h }
        else
          render json: ErrorSerializer.serialize(["The team already has a tag named #{tag.name}"], status: 422),
                 status: :unprocessable_content
        end
      end

      private

      # A private label is changed by its owner alone; another member's is a
      # 404, as if it did not exist. A team tag needs an owner or admin.
      def editable_tag
        tag = current_organization.tags.visible_to(current_membership).find_by!(key: params[:id])
        return tag if tag.private?

        require_role!(*Membership::ADMIN_ROLES)
        performed? ? nil : tag
      end

      def forbidden
        render json: ErrorSerializer.serialize("Forbidden", status: 403), status: :forbidden
      end

      def tag_params
        params.permit(:name, :color)
      end
    end
  end
end
