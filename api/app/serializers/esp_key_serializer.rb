class EspKeySerializer < ApplicationSerializer
  attributes :name, :prefix, :last_used_at, :created_at
end
