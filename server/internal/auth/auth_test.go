package auth

import "testing"

func TestPasswordRoundTrip(t *testing.T) {
	hash, err := HashPassword("correct horse battery staple")
	if err != nil {
		t.Fatalf("hash: %v", err)
	}
	if err := VerifyPassword("correct horse battery staple", hash); err != nil {
		t.Fatalf("verify good password: %v", err)
	}
	if err := VerifyPassword("wrong password", hash); err == nil {
		t.Fatal("expected mismatch for wrong password")
	}
}

func TestTokenIssueVerify(t *testing.T) {
	tm := NewTokenManager("test-secret")
	access, refresh, err := tm.Issue("user-123")
	if err != nil {
		t.Fatalf("issue: %v", err)
	}

	uid, err := tm.Verify(access, "access")
	if err != nil || uid != "user-123" {
		t.Fatalf("verify access: uid=%q err=%v", uid, err)
	}

	uid, err = tm.Verify(refresh, "refresh")
	if err != nil || uid != "user-123" {
		t.Fatalf("verify refresh: uid=%q err=%v", uid, err)
	}

	// Access token must not validate as a refresh token and vice versa.
	if _, err := tm.Verify(access, "refresh"); err == nil {
		t.Fatal("access token should not verify as refresh")
	}

	// Wrong secret must fail.
	other := NewTokenManager("different-secret")
	if _, err := other.Verify(access, "access"); err == nil {
		t.Fatal("token verified under wrong secret")
	}
}
