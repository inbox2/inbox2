# One recorded click in a tracked link's history (who/when/where).
class LinkClickSerializer < ::ApplicationSerializer
  attributes :ip, :user_agent, :geo_country, :geo_city, :proxied, :proxy_kind, :clicked_at
end
