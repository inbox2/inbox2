# Publishes one ESP delivery to the mail queue: the first attempt and each retry.
# The delivery is claimed first, so however many jobs name it, one publishes.
class Esp::DeliverJob < ApplicationJob
  queue_as :default

  def perform(delivery_id)
    delivery = Esp::Delivery.find_by(id: delivery_id)&.claim!
    return unless delivery

    Esp::Publisher.publish(delivery)
  rescue StandardError
    delivery.release! if delivery
    raise
  end
end
