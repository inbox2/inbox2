FactoryBot.define do
  factory :push_device do
    user
    platform { PushDevice::PLATFORM_IOS }
    environment { PushDevice::ENV_PRODUCTION }
    sequence(:token) { |n| "device-token-#{n}-#{SecureRandom.hex(8)}" }
    device_name { "Test iPhone" }
    last_registered_at { Time.current }
  end
end
