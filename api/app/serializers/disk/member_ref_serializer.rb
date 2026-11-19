module Disk
  # A member as Disk shows them: public id and display name.
  class MemberRefSerializer
    include Alba::Resource

    attribute :id, &:key

    attribute :name do |m|
      Disk.display_name(m)
    end

    # True when this is an agent acting through its membership (build guide 9c).
    attribute :agent, &:agent?
  end
end
