# Each claim of a mail import bumps run; a job keeps writing only while the row
# still carries its run, so a stopped job can't overwrite the next run's cursor.
class AddRunToMailImports < ActiveRecord::Migration[8.1]
  def change
    add_column :mail_imports, :run, :integer, default: 0, null: false, if_not_exists: true
  end
end
