package clipboard

import "testing"

func TestBestClipboardTextPrefersCleanPlainText(t *testing.T) {
	text := bestClipboardText([]clipboardTextCandidate{
		{Text: "AI ����", Source: "pbpaste"},
		{Text: "AI icon", Source: "public.utf8-plain-text"},
	})

	if text != "AI icon" {
		t.Fatalf("expected clean UTF-8 plain text, got %q", text)
	}
}

func TestBestClipboardTextRejectsReplacementCharacterNoise(t *testing.T) {
	text := bestClipboardText([]clipboardTextCandidate{
		{Text: "����������icon��Ö��", Source: "pbpaste"},
	})

	if text != "" {
		t.Fatalf("expected replacement-character noise to be rejected, got %q", text)
	}
}

