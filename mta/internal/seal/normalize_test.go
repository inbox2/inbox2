package seal

import (
	"encoding/json"
	"os"
	"testing"
)

// Parity with the Rails SubjectNormalizer, pinned by vectors generated from the
// Ruby class (see normalize.go). If this fails after editing either side,
// regenerate the vectors and fix BOTH implementations to agree.
func TestNormalizeSubjectParityVectors(t *testing.T) {
	raw, err := os.ReadFile("testdata/subject_vectors.json")
	if err != nil {
		t.Fatalf("read vectors: %v", err)
	}
	var vectors []struct {
		In  string `json:"in"`
		Out string `json:"out"`
	}
	if err := json.Unmarshal(raw, &vectors); err != nil {
		t.Fatalf("parse vectors: %v", err)
	}
	if len(vectors) < 20 {
		t.Fatalf("suspiciously few vectors: %d", len(vectors))
	}
	for _, v := range vectors {
		if got := NormalizeSubject(v.In); got != v.Out {
			t.Errorf("NormalizeSubject(%q) = %q, want %q", v.In, got, v.Out)
		}
	}
}
