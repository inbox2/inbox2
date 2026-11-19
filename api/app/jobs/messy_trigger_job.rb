# Off-thread, retrying wrapper around MessyClient so transactional sends never
# block (or leak failures to) the request. Mirrors the lalaaji-v3 pattern.
class MessyTriggerJob < ApplicationJob
  queue_as :default

  retry_on StandardError, wait: :polynomially_longer, attempts: 5

  # @param method [String] MessyClient method name (e.g. "trigger")
  def perform(method, **args)
    MessyClient.new.public_send(method, **args)
  end
end
