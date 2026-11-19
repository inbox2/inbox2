module HasPublicId
  extend ActiveSupport::Concern

  included do
    before_create :generate_key
  end

  class_methods do
    def key_prefix(prefix = nil)
      if prefix
        @key_prefix = prefix
      else
        @key_prefix || name.underscore.split("/").last
      end
    end

    def find_by_key!(key)
      find_by!(key: key)
    end
  end

  private

  def generate_key
    return unless self.class.instance_variable_get(:@key_prefix)
    return if key.present?

    prefix = self.class.key_prefix
    self.key = "#{prefix}_#{Nanoid.generate(size: 21)}"
  end
end
