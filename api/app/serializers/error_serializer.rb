class ErrorSerializer
  def self.serialize(messages, status:)
    messages = Array(messages)
    {
      errors: messages.map { |msg| { message: msg } },
      status: status
    }
  end
end
