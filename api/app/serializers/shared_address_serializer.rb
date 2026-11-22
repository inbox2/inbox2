# A shared address on a domain's list (info@, support@), with who reads it and
# who may reply as it, for the console's Shared addresses card.
class SharedAddressSerializer < ::ApplicationSerializer
  attributes :local_part, :address, :display_name, :repliers
end
