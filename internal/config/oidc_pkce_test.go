package config

import "testing"

func TestOIDCEnableEnvOverride(t *testing.T) {
	for _, tc := range []struct {
		name, env        string
		configured, want bool
	}{
		{"empty preserves enabled configuration", "", true, true},
		{"empty preserves disabled configuration", "", false, false},
		{"explicitly enabled", "true", false, true},
		{"explicitly disabled", "false", true, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Setenv("OIDC_AUTH_ENABLE", tc.env)
			cfg := &Config{OIDCAuth: &OIDCAuthConfig{Enable: tc.configured}}
			applyOIDCEnvOverrides(cfg)
			if cfg.OIDCAuth.Enable != tc.want {
				t.Fatalf("OIDC enabled = %v, want %v", cfg.OIDCAuth.Enable, tc.want)
			}
		})
	}
}

func TestOIDCPKCEEnvOverride(t *testing.T) {
	for _, value := range []string{"true", "false"} {
		t.Run(value, func(t *testing.T) {
			t.Setenv("OIDC_AUTH_PKCE_ENABLED", value)
			cfg := &Config{OIDCAuth: &OIDCAuthConfig{PKCEEnabled: value != "true"}}
			applyOIDCEnvOverrides(cfg)
			if cfg.OIDCAuth.PKCEEnabled != (value == "true") {
				t.Fatal("PKCE environment override was not applied")
			}
		})
	}
}
