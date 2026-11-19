module MailClient
  # Something a mail client asked for that is refused, with the HTTP status to
  # answer the frontend with.
  class Refused < StandardError
    attr_reader :status

    def initialize(message, status: 422)
      super(message)
      @status = status
    end
  end
end
