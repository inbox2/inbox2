# One address folder (AddressFolders#tree): the Inbox, an own address, a tag
# on it, a shared address, or Other.
class FolderSerializer < ::ApplicationSerializer
  attributes :key, :kind, :address, :parent, :unread, :can_reply, :in_inbox, :notify
end
