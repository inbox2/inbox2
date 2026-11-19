# A domain's versioned E2EE sealing key (docs/E2EE.md) — public material only.
# The secret exists solely inside per-membership sealed grants, which are never
# serialized here.
class DomainKeySerializer < ::ApplicationSerializer
  attributes :version, :public_key, :retired_at, :created_at
end
