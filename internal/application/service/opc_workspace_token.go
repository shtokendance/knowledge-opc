package service

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"errors"
	"fmt"
	"time"

	"github.com/Tencent/WeKnora/internal/types"
	"github.com/golang-jwt/jwt/v5"
)

const opcWorkspaceTokenType = "opc_workspace_access"

type opcWorkspaceClaims struct {
	jwt.RegisteredClaims
	TenantID uint64 `json:"tenant_id"`
	Type     string `json:"type"`
}

func (s *userService) ValidateOPCWorkspaceToken(ctx context.Context, raw string) (*types.User, uint64, error) {
	var claims opcWorkspaceClaims
	token, err := jwt.ParseWithClaims(raw, &claims, func(_ *jwt.Token) (any, error) {
		key := hmac.New(sha256.New, []byte(getJwtSecret()))
		key.Write([]byte("opc.workspace-access.v1"))
		return key.Sum(nil), nil
	}, jwt.WithValidMethods([]string{"HS256"}), jwt.WithIssuer("platform-opc"),
		jwt.WithAudience("knowledge-opc:workspace"), jwt.WithExpirationRequired(), jwt.WithIssuedAt())
	if err != nil || !token.Valid {
		return nil, 0, errors.New("invalid OPC workspace token")
	}
	if claims.Type != opcWorkspaceTokenType || len(claims.Audience) != 1 ||
		claims.Subject == "" || claims.ID == "" || claims.TenantID == 0 || claims.IssuedAt == nil {
		return nil, 0, errors.New("invalid OPC workspace claims")
	}
	if lifetime := claims.ExpiresAt.Sub(claims.IssuedAt.Time); lifetime <= 0 || lifetime > 2*time.Minute {
		return nil, 0, errors.New("invalid OPC workspace token lifetime")
	}

	record, err := s.tokenRepo.GetTokenByValue(ctx, raw)
	if err != nil {
		return nil, 0, fmt.Errorf("look up OPC workspace token: %w", err)
	}
	if record == nil || record.IsRevoked || record.TokenType != opcWorkspaceTokenType ||
		record.ID != claims.ID || record.UserID != claims.Subject || !record.ExpiresAt.After(time.Now()) {
		return nil, 0, errors.New("inactive OPC workspace token record")
	}

	user, err := s.userRepo.GetUserByID(ctx, claims.Subject)
	if err != nil {
		return nil, 0, fmt.Errorf("load OPC workspace user: %w", err)
	}
	if user == nil || !user.IsActive {
		return nil, 0, errors.New("inactive OPC workspace user")
	}
	return user, claims.TenantID, nil
}
