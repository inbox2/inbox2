# One IdP identity (NameID) bound to one inbox2 user within one org. SSO login
# resolves the user through this row and nothing else: never by username, never
# by address. An existing member creates theirs by linking while signed in
# (SamlController#link); a first-time SSO user gets one when provisioned.
class SamlIdentity < ApplicationRecord
  key_prefix "smli"

  belongs_to :organization
  belongs_to :user

  validates :name_id, presence: true, uniqueness: { scope: :organization_id }
end
