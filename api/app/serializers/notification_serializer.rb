class NotificationSerializer < ::ApplicationSerializer
  attributes :kind, :title, :body, :url, :read, :created_at

  attribute :conversation_id do |n|
    n.conversation&.key
  end
end
