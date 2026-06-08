package db

import (
	"os"
	"path/filepath"
	"testing"
)

func TestDeleteRemovesRelativeImagePathFromDataDir(t *testing.T) {
	dir := t.TempDir()
	imagesDir := filepath.Join(dir, "images")
	if err := os.MkdirAll(imagesDir, 0755); err != nil {
		t.Fatal(err)
	}

	imagePath := filepath.Join(imagesDir, "clip.png")
	if err := os.WriteFile(imagePath, []byte("image"), 0644); err != nil {
		t.Fatal(err)
	}

	store, err := New(filepath.Join(dir, "clippy.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { store.Close() })

	item, err := store.CreateWithHash("[图片]", "image", filepath.Join("data", "images", "clip.png"), "hash")
	if err != nil {
		t.Fatal(err)
	}

	if err := store.Delete(item.ID); err != nil {
		t.Fatal(err)
	}

	if _, err := os.Stat(imagePath); !os.IsNotExist(err) {
		t.Fatalf("expected %s to be removed, stat err=%v", imagePath, err)
	}
}
