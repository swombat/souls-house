package ids

import "testing"

func TestConnectionRefs(t *testing.T) {
	for _, ok := range []string{"svc_1", "svc_12", "svc_9223372036854775807"} {
		if !ValidConnectionRef(ok) {
			t.Errorf("%q refused", ok)
		}
	}
	for _, bad := range []string{"", "svc_", "svc_0", "svc_01", "svc_1/../x", "../svc_1", "svc_1\n", "SVC_1", "svc_12345678901234567890", "svc_-1"} {
		if ValidConnectionRef(bad) {
			t.Errorf("%q accepted", bad)
		}
	}
}

func TestCommandIDs(t *testing.T) {
	if !ValidCommandID("0123456789abcdef0123456789abcdef") {
		t.Error("valid id refused")
	}
	for _, bad := range []string{"", "0123456789ABCDEF0123456789abcdef", "0123456789abcdef0123456789abcde", "0123456789abcdef0123456789abcdef0"} {
		if ValidCommandID(bad) {
			t.Errorf("%q accepted", bad)
		}
	}
}

func TestE164(t *testing.T) {
	for _, ok := range []string{"+447700900123", "+12025550123", "+3361234567", "+999999999999999"} {
		if !ValidE164(ok) {
			t.Errorf("%q refused", ok)
		}
	}
	for _, bad := range []string{"", "447700900123", "+0447700900123", "+44 7700 900123", "+44-7700900123",
		"+12345", "+1234567890123456", "+44770090012a", "+447700900123\n", "++447700900123"} {
		if ValidE164(bad) {
			t.Errorf("%q accepted", bad)
		}
	}
}
