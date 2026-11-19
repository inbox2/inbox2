FactoryBot.define do
  factory :attachment do
    message
    organization { message.organization }
    filename { "document.pdf" }
    content_type { "application/pdf" }
    size_bytes { 1024 }
  end
end
