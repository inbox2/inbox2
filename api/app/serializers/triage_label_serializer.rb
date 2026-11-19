class TriageLabelSerializer < ::ApplicationSerializer
  attributes :slug, :name, :description, :not_for, :color, :builtin, :enabled, :position
end
