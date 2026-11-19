module Api
  module V1
    # Jev triage action labels (docs/Triage.md): the thirteen built-ins every org
    # starts with plus the org's custom ones. Any member reads; admins write.
    # Built-ins keep their slug and can't be deleted; `fyi` can't be disabled
    # (TriageLabel validations).
    class TriageLabelsController < BaseController
      before_action :require_organization!
      before_action :require_admin!, except: :index

      # GET /api/v1/orgs/:org_id/triage-labels
      def index
        labels = TriageLabel.ensure_defaults(current_organization)
        render json: { triage_labels: labels.map { |l| TriageLabelSerializer.new(l).to_h } }
      end

      # POST /api/v1/orgs/:org_id/triage-labels
      def create
        # Seed first so a custom label lands after the built-ins.
        TriageLabel.ensure_defaults(current_organization)
        label = current_organization.triage_labels.build(label_params)
        label.position = current_organization.triage_labels.maximum(:position).to_i + 1 unless label_params.key?(:position)
        save_and_render(label, :created)
      end

      # PATCH/PUT /api/v1/orgs/:org_id/triage-labels/:id
      def update
        label = current_organization.triage_labels.find_by!(key: params[:id])
        label.assign_attributes(label_params)
        save_and_render(label, :ok)
      end

      # DELETE /api/v1/orgs/:org_id/triage-labels/:id
      def destroy
        label = current_organization.triage_labels.find_by!(key: params[:id])
        if label.destroy
          head :no_content
        else
          render_errors(label)
        end
      end

      private

      # E4: `builtin` is never client-settable.
      def label_params
        params.permit(:slug, :name, :description, :not_for, :color, :enabled, :position)
      end

      def require_admin!
        require_role!(*Membership::ADMIN_ROLES)
      end

      def save_and_render(label, status)
        if label.save
          render json: { triage_label: TriageLabelSerializer.new(label).to_h }, status: status
        else
          render_errors(label)
        end
      end

      def render_errors(label)
        render json: ErrorSerializer.serialize(label.errors.full_messages, status: 422), status: :unprocessable_content
      end
    end
  end
end
