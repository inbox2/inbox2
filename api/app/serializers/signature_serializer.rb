class SignatureSerializer < ::ApplicationSerializer
  attributes :name, :body_html, :from_address, :is_default, :created_at

  # personal | domain | org
  attribute :scope do |s|
    s.personal? ? "personal" : (s.domain_id ? "domain" : "org")
  end

  attribute :domain_id do |s|
    s.domain&.key
  end

  attribute :domain_name do |s|
    s.domain&.name
  end

  # Whether the viewer may change it: their own, or a shared one when they are an admin.
  attribute :editable do |s|
    m = params[:membership]
    m.present? && (s.personal? ? s.membership_id == m.id : m.admin?)
  end
end
