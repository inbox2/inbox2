class Attachment < ApplicationRecord
  key_prefix "att"

  SEARCHABLE_TYPES = %w[text/plain text/html text/csv text/markdown application/json].freeze
  PDF_TYPE = "application/pdf".freeze

  belongs_to :message
  belongs_to :organization

  # Sealed attachments (docs/E2EE.md) carry the filename only as ciphertext.
  validates :filename, presence: true, unless: :sealed?

  before_save :update_search_vector, if: :content_text_changed?
  # The message's search vector carries its attachments' text (Message::SEARCH_VECTOR_SQL).
  # Linking a draft's attachment to the sent message moves it: both messages change.
  after_save -> { Message.refresh_search_vectors([message_id, message_id_before_last_save].compact.uniq) },
             if: -> { saved_change_to_content_text? || saved_change_to_message_id? }
  # PDF text is pulled out off the request path (pdftotext on the stored object).
  after_create_commit -> { ExtractAttachmentTextJob.perform_later(id) }, if: :pdf?

  scope :searchable, -> { where.not(content_text: [nil, ""]) }

  def sealed?
    sealed_filename.present?
  end

  def pdf?
    return false if sealed?

    content_type == PDF_TYPE || File.extname(filename.to_s).casecmp?(".pdf")
  end

  def searchable?
    return false if sealed?

    SEARCHABLE_TYPES.include?(content_type) || filename_text_extension?
  end

  private

  def update_search_vector
    return if content_text.blank?

    sanitized = ActiveRecord::Base.connection.quote(content_text)
    result = ActiveRecord::Base.connection.execute(
      "SELECT to_tsvector('english', #{sanitized}) AS vector"
    ).first
    self.search_vector = result["vector"]
  end

  def filename_text_extension?
    %w[.txt .md .csv .json .log .xml .yml .yaml .html .htm].include?(File.extname(filename).downcase)
  end
end
