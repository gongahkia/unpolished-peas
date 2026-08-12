package webgpu

import "testing"

func TestSurfaceSizeValidation(t *testing.T) {
	if err := validateSurfaceSize(0, 1, false); err == nil {
		t.Fatal("zero-sized initial surface was accepted")
	}
	if err := validateSurfaceSize(0, 1, true); err != nil {
		t.Fatalf("suspended surface rejected: %v", err)
	}
	if err := validateSurfaceSize(-1, 1, true); err == nil {
		t.Fatal("negative surface dimension was accepted")
	}
	if intSize := int64(maxSurfaceDimension) + 1; intSize <= int64(maxInt()) {
		if err := validateSurfaceSize(int(intSize), 1, true); err == nil {
			t.Fatal("uint32-overflowing surface dimension was accepted")
		}
	}
}

func maxInt() int { return int(^uint(0) >> 1) }
