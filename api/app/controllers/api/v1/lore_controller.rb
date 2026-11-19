module Api
  module V1
    # The Lore ontology of an org's MX mail (docs/Ontology.md): entities, one
    # entity with its facts, and the entity graph the Explorer draws. Domain
    # scoped: a member sees entities of the domains they may read, and facts
    # and threads only from conversations they can see. Cross-tenant → 404.
    # Writes are the hand edits of docs/Ontology.md "Editing".
    class LoreController < BaseController
      before_action :require_organization!
      GRAPH_LIMIT = 300
      LIST_LIMIT = 200
      CONVERSATION_LIMIT = 50

      before_action :current_active_membership!, only: %i[update_entity destroy_entity merge_entity update_fact destroy_fact]
      rescue_from(LoreEntity::EditRefused) { |e| render_refused(e.message) }

      # GET /api/v1/orgs/:org_id/lore/entities?kind=&q=&domain=
      def entities
        scope = entity_scope
        scope = scope.where(kind: params[:kind]) if LoreEntity::KINDS.include?(params[:kind])
        if params[:q].present?
          q = "%#{LoreEntity.sanitize_sql_like(params[:q].to_s.downcase)}%"
          scope = scope.where("LOWER(lore_entities.name) LIKE :q OR lore_entities.address LIKE :q OR lore_entities.email_domain LIKE :q", q: q)
        end
        rows = scope.order(mention_count: :desc, last_seen_at: :desc).limit(LIST_LIMIT)
        render json: { entities: LoreEntitySerializer.new(rows).to_h }
      end

      # GET /api/v1/orgs/:org_id/lore/entities/:id
      def entity
        entity = entity_scope.find_by!(key: params[:id])
        visible = visible_conversations.select(:id)
        facts = entity.facts.live.where(conversation_id: nil).or(entity.facts.live.where(conversation_id: visible))
          .includes(:related_entity, :conversation).order(confidence: :desc, created_at: :desc)
        conversation_keys = visible_conversations.joins("INNER JOIN lore_mentions ON lore_mentions.conversation_id = conversations.id")
          .where(lore_mentions: { lore_entity_id: entity.id })
          .order(updated_at: :desc).limit(CONVERSATION_LIMIT).pluck(:key)
        render json: {
          entity: LoreEntitySerializer.new(entity).to_h.merge(
            facts: LoreFactSerializer.new(facts).to_h, conversations: conversation_keys
          )
        }
      end

      # PATCH lore/entities/:id  { name?, kind? }
      def update_entity
        entity = entity_scope.find_by!(key: params[:id])
        attrs = params.permit(:name, :kind)
        return render_refused("Enter a name.") if attrs.key?(:name) && attrs[:name].to_s.strip.empty?

        entity.rename!(attrs[:name]) if attrs.key?(:name)
        entity.change_kind!(attrs[:kind]) if attrs.key?(:kind)
        render json: { entity: LoreEntitySerializer.new(entity).to_h }
      end

      # DELETE lore/entities/:id. Remembered: the miner does not bring it back.
      def destroy_entity
        entity_scope.find_by!(key: params[:id]).remove!
        head :no_content
      end

      # POST lore/entities/:id/merge  { into } → the entity it was merged into
      def merge_entity
        entity = entity_scope.find_by!(key: params[:id])
        target = entity_scope.find_by!(key: params.require(:into))
        entity.merge_into!(target)
        render json: { entity: LoreEntitySerializer.new(target.reload).to_h }
      end

      # PATCH lore/entities/:id/facts/:fact_id  { name?, value? }. The fingerprint is
      # the mined identity and stays, so the miner leaves the edit alone.
      def update_fact
        fact = entity_fact
        attrs = params.permit(:name, :value).to_h.compact_blank
        return render_refused("Enter a value.") if attrs.empty?

        fact.update!(attrs.merge(confidence: 1.0))
        render json: { fact: LoreFactSerializer.new(fact).to_h }
      end

      # DELETE lore/entities/:id/facts/:fact_id
      def destroy_fact
        entity_fact.update_columns(removed_at: Time.current)
        head :no_content
      end

      # GET /api/v1/orgs/:org_id/lore/graph?domain=      # → { nodes: [{ id, kind, name, email_domain, address, weight }], links: [{ source, target, label, weight }] }
      def graph
        nodes = entity_scope.order(mention_count: :desc).limit(GRAPH_LIMIT).to_a
        ids = nodes.map(&:id)
        keys = nodes.to_h { |n| [n.id, n.key] }
        links = LoreFact.live.where(kind: LoreFact::KIND_RELATION, lore_entity_id: ids, related_entity_id: ids)
          .group(:lore_entity_id, :related_entity_id, :name).sum(:support)
          .map { |(from, to, label), weight| { source: keys[from], target: keys[to], label: label, weight: weight } }
        render json: { nodes: LoreGraphNodeSerializer.new(nodes).to_h, links: links }
      end

      private

      def entity_scope
        domain_ids = current_membership ? current_membership.accessible_domain_ids : current_organization.domains.ids
        if params[:domain].present?
          d = current_organization.domains.find_by(key: params[:domain]) || current_organization.domains.find_by(name: params[:domain].to_s.downcase)
          domain_ids = d && domain_ids.include?(d.id) ? [d.id] : []
        end
        LoreEntity.live.where(organization: current_organization, domain_id: domain_ids)
      end

      def entity_fact
        entity_scope.find_by!(key: params[:id]).facts.live.find_by!(fingerprint: params[:fact_id])
      end

      def render_refused(message)
        render json: ErrorSerializer.serialize(message, status: 422), status: :unprocessable_content
      end
    end
  end
end
