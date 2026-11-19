class WidgetConfigSerializer < ::ApplicationSerializer
  attributes :name, :status, :appearance, :behavior, :allowed_domains, :created_at

  attribute :widget_token do |widget|
    widget.widget_token
  end

  attribute :embed_script do |widget|
    "<script src=\"/widget.js\" data-token=\"#{widget.widget_token}\"></script>"
  end
end
