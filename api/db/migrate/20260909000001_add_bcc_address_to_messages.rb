# Blind-carbon recipients on an outbound message. Envelope-only: the column
# feeds RCPT TO (and the ESP adapters' bcc field); `compose_rfc5322` never emits
# a Bcc header, so recipients can't see the list.
#
# Its own file so production actually migrates (see
# 20260815000001_add_ai_summary_short_to_conversations for the why); also in the
# initial schema, hence `if_not_exists`.
class AddBccAddressToMessages < ActiveRecord::Migration[8.1]
  def change
    add_column :messages, :bcc_address, :string, if_not_exists: true
  end
end
