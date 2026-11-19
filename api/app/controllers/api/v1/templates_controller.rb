module Api
  module V1
    class TemplatesController < BaseController
      before_action :require_organization!

      # spec 8.2.1-8.2.2, A13.1
      def index
        membership = current_active_membership!
        tmpls = current_organization.templates.where(scope: Template::SCOPE_SHARED)
          .or(current_organization.templates.where(scope: Template::SCOPE_PERSONAL, membership: membership))
        render json: { templates: tmpls.map { |t| TemplateSerializer.new(t).to_h } }
      end

      def create
        membership = current_active_membership!

        # Creating a shared (org-wide) template is an admin action; a plain
        # member may only create personal templates.
        if template_params[:scope] == Template::SCOPE_SHARED
          require_role!(*Membership::ADMIN_ROLES)
        end

        tmpl = current_organization.templates.build(template_params.merge(membership: membership))
        if tmpl.save
          render json: { template: TemplateSerializer.new(tmpl).to_h }, status: :created
        else
          render json: ErrorSerializer.serialize(tmpl.errors.full_messages, status: 422), status: :unprocessable_content
        end
      end

      def update
        tmpl = find_writable_template!
        return if performed?

        # Block a member from promoting their personal template to shared.
        if template_params[:scope] == Template::SCOPE_SHARED && tmpl.scope != Template::SCOPE_SHARED
          require_role!(*Membership::ADMIN_ROLES)
        end

        if tmpl.update(template_params)
          render json: { template: TemplateSerializer.new(tmpl).to_h }
        else
          render json: ErrorSerializer.serialize(tmpl.errors.full_messages, status: 422), status: :unprocessable_content
        end
      end

      def destroy
        tmpl = find_writable_template!
        return if performed?

        tmpl.destroy!
        head :no_content
      end

      private

      # A member may only mutate their own personal template. Shared (org-wide)
      # templates require admin. Scoping the personal lookup to the caller means
      # a peer's template key 404s rather than being editable/deletable.
      def find_writable_template!
        membership = current_active_membership!
        tmpl = current_organization.templates.find_by!(key: params[:id])

        if tmpl.scope == Template::SCOPE_SHARED
          require_role!(*Membership::ADMIN_ROLES)
        elsif tmpl.membership_id != membership.id
          render json: ErrorSerializer.serialize("Template not found", status: 404), status: :not_found
        end

        tmpl
      end

      def template_params
        params.permit(:name, :body_html, :scope)
      end
    end
  end
end
