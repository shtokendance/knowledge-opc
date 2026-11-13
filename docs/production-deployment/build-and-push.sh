#!/usr/bin/env bash
# ==============================================================================
# 脚本名称: build-and-push.sh
# 作用: 按照统一命名规范编译并推送 knowledge-opc 制品镜像
# 镜像产物命名规范:
#   <REGISTRY>/knowledge-opc-app:<VERSION>
#   <REGISTRY>/knowledge-opc-ui:<VERSION>
# ==============================================================================

set -euo pipefail

# 默认配置
DEFAULT_REGISTRY="registry.cn-shanghai.aliyuncs.com/tokendance"
DEFAULT_VERSION="v2.0.0"

REGISTRY="${1:-$DEFAULT_REGISTRY}"
VERSION="${2:-$DEFAULT_VERSION}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "=========================================================================="
echo "准备构建 knowledge-opc 生产镜像"
echo "镜像仓库: ${REGISTRY}"
echo "镜像版本: ${VERSION}"
echo "项目根路径: ${PROJECT_ROOT}"
echo "=========================================================================="

# 1. 构建 knowledge-opc-app
echo ">>> [1/2] 正在构建后端镜像: ${REGISTRY}/knowledge-opc-app:${VERSION} ..."
docker build \
  -t "${REGISTRY}/knowledge-opc-app:${VERSION}" \
  -f "${SCRIPT_DIR}/Dockerfile.app" \
  --build-arg APK_MIRROR_ARG=mirrors.tencent.com \
  --build-arg WITH_ANYDOC=1 \
  --build-arg VERSION_ARG="${VERSION}" \
  --build-arg COMMIT_ID_ARG="$(git -C "${PROJECT_ROOT}" rev-parse --short HEAD 2>/dev/null || echo 'unknown')" \
  --build-arg BUILD_TIME_ARG="$(date '+%Y-%m-%d %H:%M:%S')" \
  "${PROJECT_ROOT}"

# 2. 构建 knowledge-opc-ui
echo ">>> [2/2] 正在构建前端镜像: ${REGISTRY}/knowledge-opc-ui:${VERSION} ..."
docker build \
  -t "${REGISTRY}/knowledge-opc-ui:${VERSION}" \
  -f "${SCRIPT_DIR}/Dockerfile.ui" \
  --build-arg NPM_REGISTRY=https://registry.npmmirror.com \
  --build-arg VITE_FRONTEND_COMMIT="$(git -C "${PROJECT_ROOT}" rev-parse --short HEAD 2>/dev/null || echo 'unknown')" \
  "${PROJECT_ROOT}/frontend"

echo "=========================================================================="
echo "本地镜像构建完成！"
docker images | grep "knowledge-opc-" | head -n 5

read -p "是否立即推送镜像到远程仓库？(y/N): " -r CONFIRM
if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
  echo ">>> 正在推送镜像到 ${REGISTRY} ..."
  docker push "${REGISTRY}/knowledge-opc-app:${VERSION}"
  docker push "${REGISTRY}/knowledge-opc-ui:${VERSION}"
  echo ">>> 镜像推送完成！"
else
  echo ">>> 跳过镜像推送。您可以手动执行:"
  echo "    docker push ${REGISTRY}/knowledge-opc-app:${VERSION}"
  echo "    docker push ${REGISTRY}/knowledge-opc-ui:${VERSION}"
fi
