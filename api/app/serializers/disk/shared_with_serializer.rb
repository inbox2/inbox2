module Disk
  # A node's Access column: people with their own grant on it (first few),
  # how many in all, and whether access is also inherited from above.
  class SharedWithSerializer
    include Alba::Resource

    attributes :total, :inherited

    many :people, resource: Disk::GrantRefSerializer
  end
end
