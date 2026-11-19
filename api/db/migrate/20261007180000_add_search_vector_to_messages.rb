# Search reaches message bodies and attachment text (2026-10-07). Until now MX
# search matched only a conversation's subject/snippet/addresses and attachment
# filenames, so a word in the body or inside an attached PDF never hit.
# One vector per message: body + its attachments' text together, so a query can
# match "btw sizio" in the body and "nummer" in the PDF at once. Sealed mail
# stays NULL — the server has no plaintext to index.
class AddSearchVectorToMessages < ActiveRecord::Migration[8.1]
  def up
    add_column :messages, :search_vector, :tsvector, if_not_exists: true
    add_index :messages, :search_vector, using: :gin, if_not_exists: true
    Message.refresh_search_vectors(Message.all)
    # PDFs that arrived before extraction existed (a handful on prod).
    Attachment.where(content_text: nil, sealed_filename: nil).select(&:pdf?).each do |a|
      ExtractAttachmentTextJob.perform_later(a.id)
    end
  end

  def down
    remove_column :messages, :search_vector, if_exists: true
  end
end
