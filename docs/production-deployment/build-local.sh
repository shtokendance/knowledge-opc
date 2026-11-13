#!/usr/bin/env bash
# ==============================================================================
# 脚本名称: build-local.sh
# 适用场景: 正式生产服务器线上就地构建部署
# 工作机制:
#   1. 检查当前是否处于 release 分支
#   2. 自动拉取最新的 Git Commit ID（前 7 位 short hash）
#   3. 使用短 commit 生成镜像版本号: knowledge-opc-xxx:<COMMIT_ID>
#   4. 在服务器本地执行 Docker build 生成最终镜像，无需外部镜像仓库
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

cd "${PROJECT_ROOT}"

# 1. 检查 Git 分支
CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'unknown')"
if [ "${CURRENT_BRANCH}" != "release" ]; then
  echo "警告: 当前分支是 '${CURRENT_BRANCH}'，建议在 'release' 分支进行生产构建！"
  read -p "是否继续构建？(y/N): " -r CONFIRM_BRANCH
  if [[ ! "$CONFIRM_BRANCH" =~ ^[Yy]$ ]]; then
    echo "构建已终止。"
    exit 1
  fi
fi

# 2. 提取当前 release 分支 commit 7 位 short hash
COMMIT_ID="$(git rev-parse --short=7 HEAD 2>/dev/null || echo 'unknown')"
BUILD_TIME="$(date '+%Y-%m-%d %H:%M:%S')"

# 允许外部通过参数覆盖版本号，默认采用 release 分支 commit
VERSION="${1:-${COMMIT_ID}}"

APP_IMAGE="knowledge-opc-app:${VERSION}"
UI_IMAGE="knowledge-opc-ui:${VERSION}"

echo "=========================================================================="
echo "准备就地构建 knowledge-opc 生产镜像"
echo "当前分支:   ${CURRENT_BRANCH}"
echo "Commit ID:  ${COMMIT_ID}"
echo "镜像版本号: ${VERSION}"
echo "后端镜像名: ${APP_IMAGE}"
echo "前端镜像名: ${UI_IMAGE}"
echo "=========================================================================="

# 3. 本地构建 knowledge-opc-app
echo ">>> [1/2] 正在本地构建后端服务镜像: ${APP_IMAGE} ..."
docker build \
  -t "${APP_IMAGE}" \
  -f "${SCRIPT_DIR}/Dockerfile.app" \
  --build-arg APK_MIRROR_ARG=mirrors.tencent.com \
  --build-arg WITH_ANYDOC=1 \
  --build-arg VERSION_ARG="${VERSION}" \
  --build-arg COMMIT_ID_ARG="${COMMIT_ID}" \
  --build-arg BUILD_TIME_ARG="${BUILD_TIME}" \
  "${PROJECT_ROOT}"

# 4. 本地构建 knowledge-opc-ui
echo ">>> [2/2] 正在本地构建前端服务镜像: ${UI_IMAGE} ..."
docker build \
  -t "${UI_IMAGE}" \
  -f "${SCRIPT_DIR}/Dockerfile.ui" \
  --build-arg NPM_REGISTRY=https://registry.npmmirror.com \
  --build-arg VITE_FRONTEND_COMMIT="${COMMIT_ID}" \
  "${PROJECT_ROOT}/frontend"

# 5. 同时打上 latest 标签方便本地 compose 调度
docker tag "${APP_IMAGE}" "knowledge-opc-app:latest"
docker tag "${UI_IMAGE}" "knowledge-opc-ui:latest"

# 6. 将当前版本号同步记录至部署环境变量文件
PROD_ENV_FILE="${SCRIPT_DIR}/.env.production"
if [ -f "${PROD_ENV_FILE}" ]; then
  if grep -q "^KNOWLEDGE_OPC_VERSION=" "${PROD_ENV_FILE}"; then
    sed -i.bak "s/^KNOWLEDGE_OPC_VERSION=.*/KNOWLEDGE_OPC_VERSION=${VERSION}/" "${PROD_ENV_FILE}" && rm -f "${PROD_ENV_FILE}.bak"
  else
    echo "KNOWLEDGE_OPC_VERSION=${VERSION}" >> "${PROD_ENV_FILE}"
  fi
  echo ">>> 已更新 .env.production 中的 KNOWLEDGE_OPC_VERSION=${VERSION}"
fi

echo "=========================================================================="
echo "生产镜像构建完成！当前本地镜像列表:"
docker images | grep -E "knowledge-opc-(app|ui)" | head -n 4
echo "=========================================================================="
echo "下一步操作提示:"
echo "1. 进入编排目录并使用更新后的镜像启动:"
echo "   docker compose -f ${SCRIPT_DIR}/docker-compose.production.yml up -d"
