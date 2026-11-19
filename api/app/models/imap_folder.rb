# One person's IMAP folder: its UIDVALIDITY and the next UID to hand out
# (MailClient::Mailbox).
class ImapFolder < ApplicationRecord
  belongs_to :membership
end
