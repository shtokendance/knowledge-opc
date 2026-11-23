package middleware

import (
	"net/http"
	"strconv"

	"github.com/Tencent/WeKnora/internal/config"
	"github.com/Tencent/WeKnora/internal/types"
	"github.com/Tencent/WeKnora/internal/types/interfaces"
	"github.com/gin-gonic/gin"
)

func allowsOPCWorkspaceToken(c *gin.Context) bool {
	switch c.FullPath() {
	case "/api/v1/skills/catalog", "/api/v1/skills/catalog/:id", "/api/v1/skills/catalog/:id/archive",
		"/api/v1/knowledge-bases", "/api/v1/shared-knowledge-bases",
		"/api/v1/knowledge/:id", "/api/v1/knowledge/:id/download",
		"/api/v1/integration/mcp/services", "/api/v1/integration/mcp/invocations/:id",
		"/api/v1/mcp-services/:id/metadata":
		return c.Request.Method == http.MethodGet
	case "/api/v1/knowledge-bases/:id/hybrid-search", "/api/v1/integration/mcp/invocations",
		"/api/v1/integration/mcp/invocations/:id/cancel", "/api/v1/integration/mcp/invocations/:id/decision":
		return c.Request.Method == http.MethodPost
	default:
		return false
	}
}

func authenticateOPCWorkspace(c *gin.Context, tenants interfaces.TenantService, members interfaces.TenantMemberService, cfg *config.Config, user *types.User, tenantID uint64) bool {
	if !rbacEnforcementEnabled(cfg) || tenants == nil || members == nil {
		c.AbortWithStatusJSON(http.StatusForbidden, gin.H{"error": "OPC workspace authorization is unavailable"})
		return false
	}
	if selected := c.Request.Header.Values("X-Tenant-ID"); len(selected) != 0 {
		if expected := strconv.FormatUint(tenantID, 10); len(selected) != 1 || selected[0] != expected {
			c.AbortWithStatusJSON(http.StatusForbidden, gin.H{"error": "OPC workspace token cannot select another workspace"})
			return false
		}
	}
	ctx := c.Request.Context()
	tenant, err := tenants.GetTenantByID(ctx, tenantID)
	if err != nil || tenant == nil || tenant.Status != "active" {
		c.AbortWithStatusJSON(http.StatusForbidden, gin.H{"error": "OPC workspace is unavailable"})
		return false
	}
	member, err := members.GetMembership(ctx, user.ID, tenantID)
	if err != nil || member == nil || member.Status != types.TenantMemberStatusActive || !member.Role.IsValid() {
		c.AbortWithStatusJSON(http.StatusForbidden, gin.H{"error": "No active membership in the OPC workspace"})
		return false
	}

	scopedUser := *user
	scopedUser.TenantID = tenantID
	scopedUser.Tenant = tenant
	scopedUser.IsSystemAdmin = false
	scopedUser.CanAccessAllTenants = false
	applyAuthSession(c, authSession{
		User:       &scopedUser,
		Principal:  types.Principal{Type: types.PrincipalWebUser, ID: user.ID},
		TenantID:   tenantID,
		Tenant:     tenant,
		Role:       member.Role,
		AuthSource: types.AuthSourceWeb,
	})
	return true
}
