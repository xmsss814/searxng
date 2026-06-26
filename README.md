# SearXNG + Nginx + Basic Auth 一键部署

使用 Docker Compose 部署 [SearXNG](https://github.com/searxng/searxng) 元搜索引擎，通过 Nginx 反向代理 + HTTP Basic Auth 实现访问限制。

支持 **HTTP** 和 **HTTPS** 两种部署模式，HTTPS 模式可自动识别用户上传的 SSL 证书。

---

## 项目结构

```
searxng/
├── .env                          # 环境变量配置 (域名/端口/用户名/密码)
├── .env.example                  # 环境变量配置的样例文件
├── docker-compose.yml            # HTTP 模式部署文件
├── docker-compose.https.yml      # HTTPS 模式部署文件 (TLS + HTTP→HTTPS 重定向)
├── setup.sh                      # 一键部署脚本
├── .gitignore
├── nginx/
│   ├── nginx.conf                # Nginx 主配置 (worker/gzip/速率限制)
│   ├── conf.d/
│   │   ├── http/
│   │   │   └── searxng-http.conf     # HTTP 站点配置
│   │   └── https/
│   │       └── searxng-https.conf    # HTTPS 站点配置 (TLS 安全头)
│   └── .htpasswd                 # Basic Auth 密码文件 (setup.sh 自动生成)
├── searxng/
│   └── settings.yml              # SearXNG 应用配置 (搜索引擎/UI/插件)
└── certs/                        # SSL 证书目录
    ├── fullchain.pem             # 证书 / 证书链 (可为软链接)
    └── privkey.pem               # 私钥 (可为软链接)
```

---

## 环境变量说明 (`.env`)

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `SEARXNG_PORT` | SearXNG 容器内部端口 (无需修改) | `8080` |
| `HTTP_PORT` | Nginx HTTP 对外端口 | `9080` |
| `HTTPS_PORT` | Nginx HTTPS 对外端口 | `9443` |
| `DOMAIN` | 域名或 IP (用于生成 base_url 和自签名证书 CN) | `localhost` |
| `SEARXNG_BASE_URL` | **重要**: SearXNG 用于生成重定向链接的基础 URL | `http://localhost:9080` |
| `AUTH_USER` | Basic Auth 用户名 | `admin` |
| `AUTH_PASSWORD` | Basic Auth 密码 (明文, setup.sh 用 htpasswd 加密) | `admin123` |
| `CERT_PATH` | HTTPS 证书存放路径 | `./certs` |
| `LETSENCRYPT_EMAIL` | Let's Encrypt 通知邮箱 | `admin@example.com` |

> ⚠️ **`SEARXNG_BASE_URL` 必须设置**：SearXNG 用它生成所有重定向链接（如保存偏好设置后跳转的地址）。如果设置错误，你会被重定向到 `localhost` 等不可达的地址。应设置为用户实际访问的完整 URL，例如 `http://your-domain:9080` 或 `https://your-domain.com:9443`。

---

## 快速开始

### 1. 编辑 `.env` 配置

```bash
cp .env.example .env && vi .env
```

最少需要修改的项：

```ini
DOMAIN=your-domain.com          # 或服务器IP
HTTP_PORT=9080                  # HTTP 对外端口
SEARXNG_BASE_URL=http://your-domain.com:9080
AUTH_USER=your_username
AUTH_PASSWORD=your_strong_password
```

### 2. 生成 SearXNG 密钥 (可选但推荐)

```bash
openssl rand -hex 32
```

将输出填入 `searxng/settings.yml` 的 `server.secret_key` 字段。

### 3. 部署

#### HTTP 模式 (快速测试 / 内网使用)

```bash
chmod +x setup.sh
./setup.sh
```

访问: `http://${DOMAIN}:${HTTP_PORT}`

#### HTTPS 模式 (生产环境推荐)

```bash
./setup.sh --https
```

访问: `https://${DOMAIN}:${HTTPS_PORT}` (HTTP 自动 301 重定向到 HTTPS)

---

## 使用自定义 SSL 证书 (HTTPS 模式)

### 证书文件要求

将证书和私钥文件放入 `certs/` 目录：

| 文件类型 | 扩展名 | 说明 |
|----------|--------|------|
| 证书 | `.pem` 或 `.crt` | 单域名证书或 fullchain 证书链 |
| 私钥 | `.key` | PEM 格式私钥 |

**支持的私钥格式**：
- `-----BEGIN PRIVATE KEY-----` (PKCS#8)
- `-----BEGIN RSA PRIVATE KEY-----` (PKCS#1)
- `-----BEGIN EC PRIVATE KEY-----` (椭圆曲线)

**示例**：
```
certs/
├── example.com.key           ← 私钥
├── example.com.pem           ← 证书 (或 fullchain)
├── ca-bundle.pem             ← 链证书 (如有)
```

### 自动检测流程

执行 `./setup.sh --https` 时，脚本会：

1. **自动扫描** `certs/` 下的 `.key`、`.pem`、`.crt` 文件
2. **格式验证** — 检查是否为合法 PEM 格式
3. **配对验证** — 比对私钥和证书的 modulus 是否一致
4. **过期检查** — 已过期的证书直接报错；30 天内到期给出警告
5. **软链接映射** — 自动创建 `fullchain.pem` → 你的证书、`privkey.pem` → 你的私钥 的软链接
6. 如果**未检测到**用户证书，则生成自签名证书（`/CN=<DOMAIN>`）

### 手动准备证书

如果你不想使用脚本的自动检测，也可以手动创建软链接：

```bash
cd certs
ln -sf example.com.key  privkey.pem
ln -sf example.com.pem  fullchain.pem
```

Nginx 始终读取 `fullchain.pem` 和 `privkey.pem`。

---

## 手动部署 (不使用 setup.sh)

### HTTP 模式

```bash
# 1. 生成密码文件
htpasswd -bc nginx/.htpasswd your_username your_password

# 2. 启动服务
docker compose up -d
```

### HTTPS 模式 (自签名证书)

```bash
# 1. 生成密码文件
htpasswd -bc nginx/.htpasswd your_username your_password

# 2. 生成自签名证书 (仅测试用)
mkdir -p certs
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout certs/privkey.pem \
    -out certs/fullchain.pem \
    -subj "/CN=your-domain.com"

# 3. 启动
docker compose -f docker-compose.https.yml up -d
```

### HTTPS 模式 (使用你自己的证书)

```bash
# 1. 生成密码文件
htpasswd -bc nginx/.htpasswd your_username your_password

# 2. 将证书放入 certs/ 并创建软链接
#    certs/your-domain.key   → 私钥
#    certs/your-domain.pem   → 证书 (fullchain)
cd certs
ln -sf your-domain.key  privkey.pem
ln -sf your-domain.pem  fullchain.pem
cd ..

# 3. 启动
docker compose -f docker-compose.https.yml up -d
```

---

## 验证部署

```bash
# 不带认证 — 应返回 401 Unauthorized
curl -I http://localhost:9080

# 带认证 — 应返回 200 OK
curl -I -u your_username:your_password http://localhost:9080

# HTTPS 验证 (接受自签名证书用 -k)
curl -Ik -u your_username:your_password https://localhost:9443
```

---

## 速率限制

Nginx 配置了搜索接口速率限制：

| 参数 | 值 |
|------|----|
| 限流范围 | `/search` 路径 |
| 速率 | 每个 IP 每秒 10 个请求 |
| 突发 | 20 个请求 (超出部分立即处理) |
| 配置位置 | `nginx/nginx.conf` → `limit_req_zone` 指令 |

---

## 常用管理命令

```bash
# 查看所有服务日志
docker compose logs -f

# 查看单个服务日志
docker compose logs -f searxng
docker compose logs -f nginx

# 重启服务
docker compose restart

# 停止并移除容器
docker compose down

# 更新镜像并重建
docker compose pull
docker compose up -d

# 仅重新生成 .htpasswd 并重启 Nginx
htpasswd -bc nginx/.htpasswd 新用户名 新密码
docker compose restart nginx

# 查看容器状态
docker compose ps
```

---

## SearXNG 配置参考 (`searxng/settings.yml`)

| 配置项 | 说明 | 可选值 |
|--------|------|--------|
| `server.secret_key` | 会话加密密钥 | `openssl rand -hex 32` 生成 |
| `server.bind_address` | 监听地址 | `0.0.0.0` |
| `server.port` | 内部端口 | `8080` |
| `server.image_proxy` | 代理搜索结果图片 | `true` / `false` |
| `search.safe_search` | 安全搜索级别 | `0`=关闭, `1`=中等, `2`=严格 |
| `search.autocomplete` | 搜索建议 API | `""`=关闭, `"google"`, `"duckduckgo"` 等 |
| `search.default_lang` | 默认搜索语言 | `""`=自动, `"zh-Hans"`, `"en"` 等 |
| `search.formats` | 输出格式 | `html`, `json`, `csv`, `rss` |
| `ui.default_theme` | 默认主题 | `simple` |
| `ui.default_locale` | 默认界面语言 | `""`=自动, `"zh-Hans"`, `"en"` 等 |
| `ui.static_use_hash` | URL hash 版本化静态资源 | `true` |

完整文档: [https://docs.searxng.org/admin/settings/](https://docs.searxng.org/admin/settings/)

---

## 安全建议

1. **修改默认密码** — 务必修改 `.env` 中的 `AUTH_USER` / `AUTH_PASSWORD`
2. **随机化 secret_key** — 运行 `openssl rand -hex 32` 替换 `searxng/settings.yml` 中的密钥
3. **正确设置 SEARXNG_BASE_URL** — 否则保存偏好设置后会被重定向到错误的地址
4. **生产环境使用 CA 签发证书** — 不要在生产中使用自签名证书；将 `.key` / `.pem` 放入 `certs/`，脚本自动识别
5. **启用防火墙** — 仅暴露 Nginx 端口 (`HTTP_PORT` / `HTTPS_PORT`)，不直接暴露 SearXNG 的 8080 端口
6. **启用 HSTS** (HTTPS 模式) — 取消注释 `nginx/conf.d/https/searxng-https.conf` 中的 `add_header Strict-Transport-Security` 行
7. **定期更新镜像** — `docker compose pull && docker compose up -d`

---

## 故障排查

### 保存偏好设置后跳转到 localhost

检查 `.env` 中 `SEARXNG_BASE_URL` 是否正确设置。应该设为用户实际访问的完整 URL：

```ini
# 错误: 会被重定向到 localhost
SEARXNG_BASE_URL=http://localhost:9080

# 正确: 设为你的实际域名或 IP + 端口
SEARXNG_BASE_URL=http://your-server.com:18001
```

修改后需要重启容器:
```bash
docker compose down && docker compose up -d
```

### 证书密钥对不匹配

如果 Nginx 报错 `key mismatch`，检查证书和私钥是否配对：

```bash
# 比对 modulus — 两行输出应完全相同
openssl x509 -noout -modulus -in certs/fullchain.pem | md5sum
openssl rsa -noout -modulus -in certs/privkey.pem | md5sum
```

### 端口被占用

修改 `.env` 中的 `HTTP_PORT` / `HTTPS_PORT` 为其他端口，然后重启。
