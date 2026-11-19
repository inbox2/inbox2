FactoryBot.define do
  factory :organization do
    sequence(:name) { |n| "Org #{n}" }
    owner factory: :user

    # Optional explicit primary-domain name; otherwise a unique one is generated.
    # Set with_default_domain: false for an org with no domains yet.
    transient do
      domain { nil }
      with_default_domain { true }
    end

    after(:create) do |org, ev|
      if ev.with_default_domain
        create(:domain, organization: org, status: "verified",
                        name: ev.domain || "org#{org.id}.test")
      end
    end
  end
end
