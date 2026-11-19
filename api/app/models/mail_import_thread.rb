# A source thread (Gmail threadId, Graph conversationId) and the conversation it
# became, per import, so later messages of the thread land in the same place.
class MailImportThread < ApplicationRecord
  belongs_to :mail_import
  belongs_to :conversation
end
