# Pulls the text out of a PDF attachment so search can find words inside it
# (Message::SEARCH_VECTOR_SQL folds attachment text into the message's vector;
# saving content_text refreshes it). Enqueued by Attachment after create.
class ExtractAttachmentTextJob < ApplicationJob
  queue_as :default
  discard_on ActiveJob::DeserializationError

  def perform(attachment_id)
    attachment = Attachment.find_by(id: attachment_id)
    return unless attachment&.pdf? && attachment.content_text.blank? && attachment.storage_key.present?

    text = AttachmentTextExtractor.pdf_text(S3StorageService.new.download(attachment.storage_key))
    attachment.update!(content_text: text) if text
  end
end
