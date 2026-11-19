# `expect { … }.to do_a.and(not_change(…))`: compound expectations need the
# negative as a matcher of its own.
RSpec::Matchers.define_negated_matcher :not_change, :change
