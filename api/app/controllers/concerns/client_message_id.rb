# A Message-ID the client chose for what it is sending or drafting, so a queued
# client's retry (or its next draft version) finds the row it already made
# instead of making another: messages' (organization_id, message_id_header)
# index is unique. Only a well-formed `<local@domain>` is taken.
module ClientMessageId
  FORMAT = /\A<[^<>\s@]+@[^<>\s@]+>\z/

  private

  def client_message_id
    mid = params[:message_id_header].to_s
    mid if FORMAT.match?(mid)
  end
end
