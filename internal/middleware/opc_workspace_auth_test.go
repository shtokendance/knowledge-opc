package middleware

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/Tencent/WeKnora/internal/application/service"
	"github.com/Tencent/WeKnora/internal/types"
	"github.com/Tencent/WeKnora/internal/types/interfaces"
	"github.com/gin-gonic/gin"
	"github.com/golang-jwt/jwt/v5"
)

type opcWorkspaceUsers struct {
	interfaces.UserRepository
	user *types.User
}

func (r opcWorkspaceUsers) GetUserByID(_ context.Context, id string) (*types.User, error) {
	if id == r.user.ID {
		return r.user, nil
	}
	return nil, nil
}

type opcWorkspaceTokens struct {
	interfaces.AuthTokenRepository
	records map[string]*types.AuthToken
}

func (r opcWorkspaceTokens) GetTokenByValue(_ context.Context, raw string) (*types.AuthToken, error) {
	return r.records[raw], nil
}

func TestOPCWorkspaceTokenAuth(t *testing.T) {
	gin.SetMode(gin.TestMode)
	const jwtSecret = "test-knowledge-jwt-secret-for-opc-workspace"
	t.Setenv("JWT_SECRET", jwtSecret)
	key := hmac.New(sha256.New, []byte(jwtSecret))
	key.Write([]byte("opc.workspace-access.v1"))
	now := time.Now().Truncate(time.Second)
	records := map[string]*types.AuthToken{}
	sign := func(change func(jwt.MapClaims), signingKey []byte) string {
		t.Helper()
		claims := jwt.MapClaims{
			"iss": "platform-opc", "sub": "sys-admin", "aud": "knowledge-opc:workspace",
			"tenant_id": uint64(7), "iat": now.Unix(), "exp": now.Add(time.Minute).Unix(),
			"jti": "token-row", "type": "opc_workspace_access",
		}
		if change != nil {
			change(claims)
		}
		raw, err := jwt.NewWithClaims(jwt.SigningMethodHS256, claims).SignedString(signingKey)
		if err != nil {
			t.Fatal(err)
		}
		records[raw] = &types.AuthToken{
			ID: "token-row", UserID: "sys-admin", Token: raw,
			TokenType: "opc_workspace_access", ExpiresAt: now.Add(time.Minute),
		}
		return raw
	}
	raw := sign(nil, key.Sum(nil))
	tenant := &types.Tenant{ID: 7, Status: "active"}
	tenants := &fakeTenantService{tenant: tenant}
	members := newFakeMemberService()
	members.seedActive("sys-admin", 7, types.TenantRoleViewer)
	members.seedActive("sys-admin", 8, types.TenantRoleAdmin)
	user := &types.User{ID: "sys-admin", TenantID: 8, IsActive: true, IsSystemAdmin: true, CanAccessAllTenants: true}
	cfg := cfgWithRBAC(true)
	users := service.NewUserService(cfg, opcWorkspaceUsers{user: user}, opcWorkspaceTokens{records: records}, tenants, members, nil)
	router := gin.New()
	router.Use(Auth(tenants, users, members, nil, cfg))
	var caller types.Caller
	capture := func(c *gin.Context) {
		ctx := c.Request.Context()
		caller = types.CallerFromContext(ctx)
		sessionUser := c.MustGet(types.UserContextKey.String()).(*types.User)
		if types.IsSystemAdminFromContext(ctx) || sessionUser.IsSystemAdmin || sessionUser.CanAccessAllTenants || sessionUser.TenantID != 7 {
			t.Errorf("privileged attributes survived workspace authentication")
		}
		c.Status(http.StatusNoContent)
	}
	router.GET("/api/v1/skills/catalog", capture)
	router.GET("/api/v1/shared-knowledge-bases", capture)
	router.GET("/api/v1/integration/mcp/services", capture)
	router.GET("/api/v1/knowledge/:id/download", RequireRole(types.TenantRoleContributor, cfg), capture)
	router.POST("/api/v1/skills/catalog", capture)
	router.GET("/api/v1/system/admin/users", capture)

	request := func(method, path, selected, token string, want int) {
		t.Helper()
		req := httptest.NewRequest(method, path, nil)
		req.Header.Set("Authorization", "Bearer "+token)
		if selected != "" {
			req.Header.Set("X-Tenant-ID", selected)
		}
		w := httptest.NewRecorder()
		router.ServeHTTP(w, req)
		if w.Code != want {
			t.Errorf("%s %s: status=%d, want %d (%s)", method, path, w.Code, want, w.Body.String())
		}
	}
	for _, route := range []string{"/api/v1/skills/catalog", "/api/v1/shared-knowledge-bases", "/api/v1/integration/mcp/services"} {
		request(http.MethodGet, route, "7", raw, http.StatusNoContent)
		if caller != (types.Caller{TenantID: 7, UserID: "sys-admin", Role: types.TenantRoleViewer}) {
			t.Errorf("wrong workspace or role: %+v", caller)
		}
	}
	request(http.MethodGet, "/api/v1/skills/catalog", "8", raw, http.StatusForbidden)
	request(http.MethodGet, "/api/v1/knowledge/k1/download", "7", raw, http.StatusForbidden)
	request(http.MethodPost, "/api/v1/skills/catalog", "7", raw, http.StatusUnauthorized)
	request(http.MethodGet, "/api/v1/system/admin/users", "", raw, http.StatusUnauthorized)
	if _, _, err := users.ValidateToken(context.Background(), raw); err == nil {
		t.Fatal("web session authentication accepted an OPC workspace token")
	}
	if !user.IsSystemAdmin || !user.CanAccessAllTenants || user.TenantID != 8 {
		t.Fatal("workspace authentication modified the source user")
	}

	for _, test := range []struct {
		name   string
		change func(jwt.MapClaims)
		key    []byte
	}{
		{"wrong signing key", nil, []byte(jwtSecret)},
		{"wrong audience", func(claims jwt.MapClaims) { claims["aud"] = "other" }, key.Sum(nil)},
		{"wrong issuer", func(claims jwt.MapClaims) { claims["iss"] = "other" }, key.Sum(nil)},
		{"long expiry", func(claims jwt.MapClaims) { claims["exp"] = now.Add(3 * time.Minute).Unix() }, key.Sum(nil)},
		{"expired JWT", func(claims jwt.MapClaims) { claims["exp"] = now.Add(-time.Second).Unix() }, key.Sum(nil)},
		{"missing workspace", func(claims jwt.MapClaims) { delete(claims, "tenant_id") }, key.Sum(nil)},
	} {
		t.Run(test.name, func(t *testing.T) {
			request(http.MethodGet, "/api/v1/skills/catalog", "7", sign(test.change, test.key), http.StatusUnauthorized)
		})
	}
	records[raw].IsRevoked = true
	request(http.MethodGet, "/api/v1/skills/catalog", "7", raw, http.StatusUnauthorized)
	records[raw].IsRevoked = false
	user.IsActive = false
	request(http.MethodGet, "/api/v1/skills/catalog", "7", raw, http.StatusUnauthorized)
	user.IsActive = true
	delete(members.members, memberKey("sys-admin", 7))
	request(http.MethodGet, "/api/v1/skills/catalog", "7", raw, http.StatusForbidden)
}
