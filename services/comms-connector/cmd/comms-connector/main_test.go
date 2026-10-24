package main

import (
	"bytes"
	"encoding/base64"
	"os"
	"os/exec"
	"strings"
	"testing"
)

// Each required setting missing makes the binary refuse to start, with a
// fixed reason and no value in the log.
func TestStartupRefusals(t *testing.T) {
	if os.Getenv("COMMS_MAIN_HELPER") == "1" {
		os.Exit(run())
	}
	good := map[string]string{
		"COMMS_STORE_KEY":   base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{1}, 32)),
		"COMMS_COMMAND_KEY": strings.Repeat("k", 40),
		"COMMS_RAILS_URL":   "http://127.0.0.1:1",
		"COMMS_DATA_DIR":    t.TempDir(),
	}
	cases := []struct{ unset, set, value, reason string }{
		{unset: "COMMS_STORE_KEY", reason: "store_key"},
		{unset: "COMMS_COMMAND_KEY", reason: "command_key"},
		{set: "COMMS_COMMAND_KEY", value: "short", reason: "command_key"},
		{unset: "COMMS_RAILS_URL", reason: "rails_url"},
		{set: "COMMS_RAILS_URL", value: "http://rails/with/path", reason: "rails_url"},
		{reason: "tls"}, // no certificates configured at all
		{set: "GOTRACEBACK", value: "all", reason: "gotraceback"},
	}
	for _, c := range cases {
		cmd := exec.Command(os.Args[0], "-test.run=TestStartupRefusals")
		cmd.Env = []string{"COMMS_MAIN_HELPER=1", "PATH=" + os.Getenv("PATH")}
		for k, v := range good {
			if k != c.unset {
				cmd.Env = append(cmd.Env, k+"="+v)
			}
		}
		if c.set != "" {
			cmd.Env = append(cmd.Env, c.set+"="+c.value)
		}
		out, err := cmd.CombinedOutput()
		if err == nil || !strings.Contains(string(out), `"reason":"`+c.reason+`"`) {
			t.Errorf("%+v: %v %s", c, err, out)
		}
		if strings.Contains(string(out), good["COMMS_COMMAND_KEY"]) || strings.Contains(string(out), good["COMMS_STORE_KEY"]) {
			t.Errorf("%+v: a key reached the log", c)
		}
	}
}
