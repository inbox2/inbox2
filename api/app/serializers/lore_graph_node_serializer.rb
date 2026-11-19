class LoreGraphNodeSerializer < ::ApplicationSerializer
  attributes :kind, :name, :email_domain, :address

  attribute :weight, &:mention_count
end
