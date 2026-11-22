# Mail to waseem+receipts@ used to land unowned in the domain's inbox, readable
# by everyone with domain access. Re-stamp those threads as their owner's own
# mail (Organization#personal_membership_id_for now drops the +tag). Data only.
class BackfillPlusAddressOwnership < ActiveRecord::Migration[8.1]
  def up
    Conversation.where(personal_membership_id: nil, private: false)
      .where("to_address LIKE ?", "%+%@%").includes(:organization).find_each do |c|
      id = c.organization.personal_membership_id_for(c.to_address)
      c.update_column(:personal_membership_id, id) if id
    end
  end

  def down; end
end
