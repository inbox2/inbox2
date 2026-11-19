# Mines one MX conversation into the domain's Lore ontology (LoreMiner,
# docs/Ontology.md), off the ingest hot path. Enqueued per inbound plaintext
# message beside the triage job; the LLM half is paid-gated inside the miner.
class LoreMineJob < ApplicationJob
  queue_as :default
  discard_on ActiveJob::DeserializationError

  def perform(conversation_id, from_name = nil)
    conversation = Conversation.find_by(id: conversation_id)
    LoreMiner.new(conversation).call(from_name: from_name) if conversation
  end
end
