# Send-as moves from the domain (anyone who sees glu0n.com could send as info@)
# to the member: an admin grants each person the exact addresses they may send
# as, on their console page (Membership#send_as_addresses).
class MoveSharedAddressesToMemberSendAs < ActiveRecord::Migration[8.1]
  def change
    add_column :memberships, :send_as_addresses, :string, array: true, default: [], null: false, if_not_exists: true
    remove_column :domains, :shared_addresses, :string, array: true, default: [], null: false, if_exists: true
  end
end
