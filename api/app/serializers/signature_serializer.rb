class SignatureSerializer < ::ApplicationSerializer
  attributes :name, :body_html, :from_address, :is_default, :created_at
end
