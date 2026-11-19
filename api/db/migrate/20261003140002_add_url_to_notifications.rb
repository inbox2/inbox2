# Where an in-app notification leads when it is not about a conversation: a
# path inside the web app, e.g. a Disk folder shared with the reader.
class AddUrlToNotifications < ActiveRecord::Migration[8.1]
  def change
    add_column :notifications, :url, :string, if_not_exists: true
  end
end
