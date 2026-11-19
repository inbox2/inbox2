require "rails_helper"

# Cross-implementation parity pin (docs/E2EE.md Phase C): the Go MX port of
# SubjectNormalizer (mta/internal/seal/normalize.go) must produce identical
# output — the threading subject_hmac is computed Go-side for sealed mail and
# Rails-side for plaintext mail. Both suites assert the same vector file; if
# you change the normalizer, regenerate the vectors and fix BOTH sides.
RSpec.describe SubjectNormalizer, "Go/Ruby parity vectors" do
  VECTORS_PATH = Rails.root.join("../mta/internal/seal/testdata/subject_vectors.json")

  it "matches every pinned vector" do
    skip "vectors file not present (mta checkout missing)" unless File.exist?(VECTORS_PATH)

    vectors = JSON.parse(File.read(VECTORS_PATH))
    expect(vectors.length).to be >= 20
    vectors.each do |v|
      expect(SubjectNormalizer.normalize(v["in"])).to eq(v["out"]), "input: #{v['in'].inspect}"
    end
  end
end
