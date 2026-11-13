# knowledge-opc 生产环境部署标准操作程序 (SOP)

本文档适用于 `knowledge-opc` 项目在正式生产服务器上进行**拉取 `release` 代码、就地编译构建、生成 Commit 镜像版本并一键拉起服务**的标准化交付运维流程。

---

## 一、生产环境统一命名与版本规范

正式环境全链路统一采用 **`knowledge-opc-xxx`** 命名规范，并以 **`release` 分支的 7 位短 Git Commit ID** 作为镜像版本号：

| 层级 | 统一命名与版本规则 | 示例 / 说明 |
| :--- | :--- | :--- |
| **后端制品名** | `knowledge-opc-app` (容器内入口 `/app/WeKnora`) | 核心 Go 编译二进制制品 |
| **前端制品名** | `knowledge-opc-ui` | Vue3/Vite 编译生产 Bundle（内置于 Nginx） |
| **后端生产镜像** | `knowledge-opc-app:<COMMIT_ID>` | 例如 `knowledge-opc-app:95f7719`，同时打上 `latest` 标签 |
| **前端生产镜像** | `knowledge-opc-ui:<COMMIT_ID>` | 例如 `knowledge-opc-ui:95f7719`，同时打上 `latest` 标签 |
| **Compose 服务名** | `knowledge-opc-app` / `knowledge-opc-ui` | `docker-compose.production.yml` 内声明的服务名 |
| **运行容器名 (Container)** | `knowledge-opc-app` / `knowledge-opc-ui` | `docker ps` 展示的容器名称 |
| **依赖组件服务名** | `knowledge-opc-postgres`<br>`knowledge-opc-redis`<br>`knowledge-opc-minio`<br>`knowledge-opc-milvus`<br>`knowledge-opc-docreader` | 数据库、缓存、对象存储、向量库、文档解析等中间件容器名 |
| **Docker 独立网络** | `knowledge-opc-network` | 容器隔离通信的 bridge 网络 |
| **数据持久卷 (Volumes)** | `knowledge-opc-postgres-data`<br>`knowledge-opc-minio-data`<br>`knowledge-opc-app-files` 等 | 具名数据存储卷，便于运维备份 |

---

## 二、部署物料清单与目录结构

所有生产部署模板与脚本均保存在代码仓库的 `docs/production-deployment/` 目录中：

```text
knowledge-opc/docs/production-deployment/
├── PRODUCTION_DEPLOYMENT_SOP.md     # 本 SOP 运维操作指南
├── build-local.sh                   # 【核心】基于 release 分支 commit 就地编译与版本标记脚本
├── Dockerfile.app                    # 后端生产多阶段构建 Dockerfile
├── Dockerfile.ui                     # 前端生产打包与 Nginx 托管 Dockerfile
├── docker-compose.production.yml     # 生产服务栈编排配置
├── .env.production.example           # 生产环境变量全量配置模板
├── config.yaml.production.example    # 生产业务配置与算法阈值模板
└── build-and-push.sh                 # （备用）外部镜像仓库编译与推送脚本
```

---

## 三、生产环境就地构建与部署全流程 (Step-by-Step)

### 步骤 1：在线上生产服务器克隆 / 拉取 `release` 代码

登录正式生产服务器，在发布目录下拉取最新 `release` 分支：

```bash
# 若为首次部署：克隆仓库
git clone <git-repo-url> /data/knowledge-opc
cd /data/knowledge-opc

# 切换并同步最新 release 分支
git checkout release
git pull origin release

# 查看当前 release 分支 commit 7 位校验码
git rev-parse --short=7 HEAD
```

---

### 步骤 2：初始化生产配置文件（仅首次或配置变更时）

进入部署目录并从模板初始化配置文件：

```bash
cd /data/knowledge-opc/docs/production-deployment

# 复制环境变量模板
cp .env.production.example .env.production
cp config.yaml.production.example config.yaml
```

**配置秘钥与基础设施**：
1. 生成高强度随机密钥并填入 `.env.production`：
   ```bash
   openssl rand -hex 16  # 作为 SYSTEM_AES_KEY, TENANT_AES_KEY
   openssl rand -hex 32  # 作为 JWT_SECRET
   ```
2. 按实际情况配置 `.env.production` 中的 `DB_PASSWORD`、`REDIS_PASSWORD`、`MINIO_SECRET_ACCESS_KEY` 及企业微信 / OIDC 参数。

---

### 步骤 3：执行线上就地编译与镜像打包（基于 commit 版本号）

直接运行提供的生产自动化构建脚本：

```bash
cd /data/knowledge-opc/docs/production-deployment
./build-local.sh
```

> **该脚本自动完成以下操作**：
> 1. 严格校验当前 Git 分支必须为 `release`；
> 2. 自动提取当前 Git commit 的前 7 位 hash（例如 `95f7719`）；
> 3. 分别构建两阶段镜像，生成带版本号与 `latest` 标签的镜像：
>    - `knowledge-opc-app:95f7719` 与 `knowledge-opc-app:latest`
>    - `knowledge-opc-ui:95f7719` 与 `knowledge-opc-ui:latest`
> 4. 自动将该版本号写入 `.env.production` 的 `KNOWLEDGE_OPC_VERSION=95f7719`。

---

### 步骤 4：启动容器编排与验证

```bash
cd /data/knowledge-opc/docs/production-deployment

# 启动全量生产服务栈
docker compose -f docker-compose.production.yml --env-file .env.production up -d
```

**验证步骤**：
1. **查看容器运行状态**：
   ```bash
   docker compose -f docker-compose.production.yml ps
   ```
   *确认所有 `knowledge-opc-*` 容器均处于 `Up` 或 `Up (healthy)` 状态。*

2. **查看后端日志与自动数据表迁移**：
   ```bash
   docker logs -f knowledge-opc-app
   ```
   *预期输出：看到数据库迁移成功日志（`Applied migration ...`），且主服务成功监听 `0.0.0.0:8080`。*

3. **测试本地端口响应**：
   ```bash
   curl -I http://localhost:80/
   curl -I http://localhost:8080/health
   ```

---

### 步骤 5：配置前置 Nginx / WAF 与 HTTPS 域名

在生产边界 Nginx（或 Cloudflare / 腾讯云 WAF）中将域名（如 `shtokendance.com`）反向代理至服务器的 `80` 端口（即 `knowledge-opc-ui`）：

```nginx
server {
    listen 443 ssl http2;
    server_name shtokendance.com;

    ssl_certificate     /etc/nginx/ssl/shtokendance.com.crt;
    ssl_certificate_key /etc/nginx/ssl/shtokendance.com.key;

    # 与前端 MAX_FILE_SIZE_MB=50 保持一致的大文件上传限制
    client_max_body_size 50m;

    location / {
        proxy_pass http://127.0.0.1:80;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;

        # 核心关键：必须关闭代理缓冲，支持大模型 SSE 打字机流式长连接
        proxy_buffering off;
        proxy_cache off;
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
    }
}
```

---

## 四、日常版本更新与回滚 SOP

### 1. 发布新版本（热更新）
当 `release` 分支有新代码合入时：
```bash
cd /data/knowledge-opc
# 1. 拉取最新 release 代码
git pull origin release

# 2. 编译新镜像（自动取最新 short commit 作为版本号）
cd docs/production-deployment
./build-local.sh

# 3. 仅重启有变更的主服务容器（平滑更新）
docker compose -f docker-compose.production.yml --env-file .env.production up -d --no-deps knowledge-opc-app knowledge-opc-ui
```

### 2. 紧急版本回滚
若新版本存在异常，只需切回上一稳定版本的 commit 或直接指定旧镜像版本：
```bash
cd /data/knowledge-opc/docs/production-deployment

# 修改 .env.production 中的 KNOWLEDGE_OPC_VERSION 为旧 commit 号，例如：
# KNOWLEDGE_OPC_VERSION=旧commit

docker compose -f docker-compose.production.yml --env-file .env.production up -d --no-deps knowledge-opc-app knowledge-opc-ui
```
