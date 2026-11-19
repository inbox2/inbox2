# One recorded open in a message's open history (who/when/where).
class MessageOpenSerializer < ::ApplicationSerializer
  attributes :ip, :user_agent, :geo_country, :geo_city, :proxied, :proxy_kind, :opened_at
end
