# knowledge-opc 生产环境部署标准操作程序 (SOP)

本文档适用于 `knowledge-opc` 项目在正式生产服务器上的标准化交付与部署。

---

## 一、生产环境统一命名规范

为保障生产环境运维、CI/CD 构建与容器治理的规范性，全链路统一采用 **`knowledge-opc-xxx`** 命名体系：

| 层级 | 统一命名规范 | 示例 / 说明 |
| :--- | :--- | :--- |
| **二进制制品名** | `knowledge-opc-app` (容器内执行入口 `WeKnora`) | 核心 Go 后端编译二进制 |
| **前端制品名** | `knowledge-opc-ui` | Vue3/Vite 编译静态 Bundle，内置于 Nginx 运行时 |
| **后端容器镜像** | `<REGISTRY>/knowledge-opc-app:<VERSION>` | 例如 `registry.cn-shanghai.aliyuncs.com/tokendance/knowledge-opc-app:v2.0.0` |
| **前端容器镜像** | `<REGISTRY>/knowledge-opc-ui:<VERSION>` | 例如 `registry.cn-shanghai.aliyuncs.com/tokendance/knowledge-opc-ui:v2.0.0` |
| **Docker Compose 服务名** | `knowledge-opc-app` / `knowledge-opc-ui` | Compose 文件内 `services` 声明 |
| **运行容器名 (Container)** | `knowledge-opc-app` / `knowledge-opc-ui` | `docker ps` 展示的容器名称 |
| **依赖组件服务名** | `knowledge-opc-postgres`<br>`knowledge-opc-redis`<br>`knowledge-opc-minio`<br>`knowledge-opc-milvus`<br>`knowledge-opc-docreader` | 数据库、缓存、对象存储、向量库、文档解析等中间件容器名 |
| **Docker 独立网络** | `knowledge-opc-network` | 容器隔离通信的 bridge 网络 |
| **数据持久卷 (Volumes)** | `knowledge-opc-postgres-data`<br>`knowledge-opc-minio-data`<br>`knowledge-opc-app-files` 等 | 具名数据存储卷，便于运维备份 |

---

## 二、部署物料清单与目录结构

所有生产部署模板与配置均已落地到代码仓库：`knowledge-opc/docs/production-deployment/`

```text
knowledge-opc/docs/production-deployment/
├── PRODUCTION_DEPLOYMENT_SOP.md     # 本 SOP 运维操作指南
├── Dockerfile.app                    # 后端生产多阶段构建 Dockerfile
├── Dockerfile.ui                     # 前端生产打包与 Nginx 托管 Dockerfile
├── build-and-push.sh                 # 自动化镜像编译与推送脚本
├── docker-compose.production.yml     # 生产服务栈编排配置
├── .env.production.example           # 生产环境变量全量配置模板
└── config.yaml.production.example    # 生产业务配置与算法阈值模板
```

---

## 三、部署实施全流程

### 阶段 1：制品构建与镜像推送（构建机 / CI 流水线）

在具备 Docker 构建环境的机器上执行自动化脚本：

```bash
# 语法: ./build-and-push.sh [镜像仓库地址] [版本号]
cd knowledge-opc/docs/production-deployment
./build-and-push.sh registry.cn-shanghai.aliyuncs.com/tokendance v2.0.0
```

> **构建说明**：
> - `Dockerfile.app` 自动启用国内加速源与 `WITH_ANYDOC=1` 内核解析引擎，编译出轻量化生产二进制 `/app/WeKnora`。
> - `Dockerfile.ui` 自动配置 `NODE_OPTIONS=--max-old-space-size=4096` 并执行 `npm ci`，产出经 Nginx 代理包装的静态前端镜像。

---

### 阶段 2：生产服务器规划与基础目录创建

登录正式生产服务器，创建规范的部署工作目录：

```bash
mkdir -p /data/knowledge-opc/{config,data/files,logs}
cd /data/knowledge-opc
```

---

### 阶段 3：落地生产配置与秘钥生成

1. **拷贝编排与配置文件模板**：
   ```bash
   # 从代码仓库或制品包复制以下文件至 /data/knowledge-opc/
   cp /path/to/docs/production-deployment/docker-compose.production.yml ./docker-compose.yml
   cp /path/to/docs/production-deployment/.env.production.example ./.env.production
   cp /path/to/docs/production-deployment/config.yaml.production.example ./config.yaml
   ```

2. **生成安全加密密钥**：
   在服务器执行命令生成强随机密码，填充至 `.env.production`：
   ```bash
   # 生成系统 AES 密钥与 JWT 密钥
   openssl rand -hex 16 # 作为 SYSTEM_AES_KEY、TENANT_AES_KEY
   openssl rand -hex 32 # 作为 JWT_SECRET
   ```

3. **按实际基础设施修改 `.env.production`**：
   - 若使用生产独立的云数据库（RDS PG、云 Redis、云 OSS）：将 `DB_HOST`、`REDIS_ADDR`、`MINIO_ENDPOINT` 修改为云服务内网 IP/域名，并在 `docker-compose.yml` 中注释掉本地容器组件。
   - 若中间件全量自建：直接保留 `docker-compose.yml` 中的组件，修改 `.env.production` 中的数据库密码与 MinIO 密码即可。
   - 配置 `SSRF_WHITELIST`：填入内部各组件的主机名或 IP。

---

### 阶段 4：启动服务与验证

1. **拉取镜像并启动容器**：
   ```bash
   cd /data/knowledge-opc
   
   # 拉取镜像
   docker compose pull
   
   # 后台启动全套服务
   docker compose up -d
   ```

2. **验证容器健康状态**：
   ```bash
   docker compose ps
   ```
   *预期输出：所有以 `knowledge-opc-` 命名的容器状态均处于 `Up` 或 `Up (healthy)`。*

3. **查看数据库自动迁移与核心服务日志**：
   ```bash
   docker logs -f knowledge-opc-app
   ```
   *预期输出：看到数据库迁移成功日志（`Applied migration ...`），并输出 `Using configuration file: ...` 和 `Server listening on 0.0.0.0:8080`。*

4. **验证前端与接口健康检查**：
   ```bash
   curl -I http://localhost:80/
   curl -I http://localhost:8080/health
   ```

---

### 阶段 5：配置前置 Nginx / 域名 HTTPS / 企微网关

在对外边界 Nginx 上配置 HTTPS 与域名绑定（以 `shtokendance.com` 为例）：

```nginx
# 生产前置 Nginx 配置
server {
    listen 443 ssl http2;
    server_name shtokendance.com;

    ssl_certificate     /etc/nginx/ssl/shtokendance.com.crt;
    ssl_certificate_key /etc/nginx/ssl/shtokendance.com.key;

    # 1. 大文件上传限制（保持与前端 MAX_FILE_SIZE_MB=50 一致）
    client_max_body_size 50m;

    # 2. 知识库前端与核心服务转发
    location / {
        proxy_pass http://127.0.0.1:80; # 指向 knowledge-opc-ui 容器端口
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;

        # 针对大模型 SSE 打字机流式输出的关键配置 (禁止缓冲)
        proxy_buffering off;
        proxy_cache off;
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
    }

    # 3. 企业微信扫码网关路由 (如果使用了统一域名转发)
    location /wecom/ {
        proxy_pass http://127.0.0.1:3002/wecom/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }
}
```

---

## 四、生产运维与避坑指南 (Checklist)

1. **SSE 流式传输截断问题**：
   - 正式环境若经过移动云 WAF / Cloudflare / 腾讯云 CLB，必须开启 **WebSocket / SSE 支持**，并关闭响应缓冲（`proxy_buffering off`），否则用户提问时看不到打字效果，甚至在大回复时报网关超时。
2. **Docker 沙箱隔离权限**：
   - 若在生产启用代码沙箱（`WEKNORA_SANDBOX_DOCKER_ENABLED=true`），必须挂载 `/var/run/docker.sock`，容器启动脚本会自动处理 `appuser` 的 GID 权限。
3. **SSRF 安全拦截**：
   - 如需在生产接入自建或局域网内的 LiteLLM / Ollama 模型，必须在 `.env.production` 的 `SSRF_WHITELIST` 中加入该服务的内网 IP 或域名，否则后端会主动拦截并报错。
4. **数据备份方案**：
   - 必须通过定时任务（Cron）对持久卷 `knowledge-opc-postgres-data`（PostgreSQL 全量 pg_dump）与 `knowledge-opc-minio-data`（MinIO 文件归档）进行异地容灾备份。
