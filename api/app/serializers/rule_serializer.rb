class RuleSerializer < ::ApplicationSerializer
  attributes :name, :enabled, :position, :conditions, :actions, :branches, :else_actions, :stop_processing, :created_at
end
