# A tracked link on a message: its destination URL + the click history.
class TrackedLinkSerializer < ::ApplicationSerializer
  attributes :url

  attribute :click_count do |link|
    link.clicks.reject(&:proxied).size
  end

  attribute :clicks do |link|
    link.clicks.map { |c| LinkClickSerializer.new(c).to_h }
  end
end
