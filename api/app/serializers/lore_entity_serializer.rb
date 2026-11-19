class LoreEntitySerializer < ::ApplicationSerializer
  attributes :kind, :name, :email_domain, :address, :mention_count, :last_seen_at, :name_locked
end
