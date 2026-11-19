class TagSerializer < ::ApplicationSerializer
  attributes :name, :color, :created_at

  # A private label: only the viewer sees it (docs/plans/mail-import.md D11).
  attribute :private, &:private?
end
