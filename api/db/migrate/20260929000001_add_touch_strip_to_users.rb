# The Touch Strip's layout + per-widget settings (clocks, weather places, tickers,
# feeds), synced to the account so every device shows the same strip. Shape is
# allow-listed in StripController; see docs/Touch-Strip.md.
class AddTouchStripToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :touch_strip, :jsonb, null: false, default: {}, if_not_exists: true
  end
end
