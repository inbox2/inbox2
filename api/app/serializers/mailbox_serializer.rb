class MailboxSerializer < ::ApplicationSerializer
  attributes :local_part, :created_at

  attribute :email_address do |mbx|
    mbx.email_address
  end

  attribute :domain do |mbx|
    { id: mbx.domain.key, name: mbx.domain.name }
  end

  attribute :membership_id do |mbx|
    mbx.membership.key
  end
end
