# Where one message sits in one person's IMAP view: folder, UID, and the flags
# that have no home in inbox2 (\Flagged, \Answered, \Deleted…). \Seen is the
# thread's read state and is not stored here (MailClient::Mailbox).
class ImapMessage < ApplicationRecord
  belongs_to :membership
  belongs_to :message
end
