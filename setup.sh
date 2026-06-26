# setup.sh
# ============================
# SeaxrXNG + Nginx + Basic Auth 一键部署脚本
#
# 宿主机零依赖: 所有工具 (htpasswd / openssl) 全部通过 Docker 容器执行
# 宿主机只需要 docker + docker compose
#
# 使用方法:
#   1. 编辑 .env 文件, 设置 AUTH_USER 和 AUTH_PASSWORD
#   2. (可选) 将你自己的 SSL 证书放入 ./certs/ 目录
#      - 私钥文件: *.key
#      - 证书文件: *.pem 或 *.crt (fullchain 或单域名证书)
#   3. HTTP 模式:  ./setup.sh
#      HTTPS 模式: ./setup.sh --https
#
# ============================

set -e

# 加载环境变量
source .env

echo "========================================="
echo "  SearXNG + Nginx + Basic Auth 部署脚本"
echo "========================================="

# ============================================
# 0. 前置检查: Docker 必须可用
# ============================================
if ! command -v docker &> /dev/null; then
    echo "❌ 错误: 未找到 docker 命令"
    echo "   请先安装 Docker: https://docs.docker.com/engine/install/"
    exit 1
fi
if ! docker info >/dev/null 2>&1; then
    echo "❌ 错误: Docker daemon 不可用, 请确认 Docker 服务已启动"
    echo "   若当前用户无权访问 Docker, 请将用户加入 docker 组或使用 sudo"
    exit 1
fi

# 当前用户/组, 用于让容器写入的文件归属当前用户
CUR_UID="$(id -u)"
CUR_GID="$(id -g)"

# 辅助函数: 通过 alpine/openssl 容器执行 openssl 命令
# 自动挂载 ./certs 到 /work, 并以当前用户身份运行
run_openssl() {
    docker run --rm \
        --user "${CUR_UID}:${CUR_GID}" \
        -v "$(pwd)/certs:/work" \
        -w /work \
        alpine/openssl "$@"
}

# ============================================
# 1. 生成 .htpasswd (通过 httpd:alpine 容器, bcrypt 加密)
# ============================================
echo "[1/?] 通过 httpd:alpine 容器生成 Basic Auth 密码文件 (bcrypt)..."
mkdir -p nginx
docker run --rm \
    --user "${CUR_UID}:${CUR_GID}" \
    -v "$(pwd)/nginx:/auth" \
    httpd:alpine \
    htpasswd -bcB /auth/.htpasswd "${AUTH_USER}" "${AUTH_PASSWORD}" >/dev/null
chmod 644 nginx/.htpasswd
echo "  用户: ${AUTH_USER}"
echo "  密码文件: nginx/.htpasswd (bcrypt 加密)"

# ============================================
# 2. 确保 SearXNG 配置目录存在
# ============================================
echo "[2/?] 创建 SearXNG 配置目录..."
mkdir -p searxng

# ============================================
# 3. 证书处理 (仅 HTTPS 模式)
# ============================================
if [ "$1" = "--https" ]; then
    echo "[3/?] 配置 SSL 证书..."
    mkdir -p certs

    # --------------------------------------------------
    # 3a. 检测用户自己上传的证书
    # --------------------------------------------------
    USER_KEY=""
    USER_CERT=""

    # 查找 .key 私钥文件 (排除 privkey.pem, 这是脚本生成的)
    for f in certs/*.key; do
        [ -f "$f" ] || continue
        if echo "$f" | grep -qv "privkey\.pem"; then
            USER_KEY="$f"
            break
        fi
    done

    # 查找 .pem / .crt 证书文件 (排除 fullchain.pem, 这是脚本生成的)
    for f in certs/*.pem certs/*.crt; do
        [ -f "$f" ] || continue
        if echo "$f" | grep -qv "fullchain\.pem" && echo "$f" | grep -qv "privkey\.pem"; then
            USER_CERT="$f"
            break
        fi
    done

    # 如果没找到 .crt, 但找到了不属于 privkey.pem 的 .pem
    if [ -z "$USER_CERT" ]; then
        for f in certs/*.pem; do
            [ -f "$f" ] || continue
            if [ "$f" != "certs/privkey.pem" ] && [ "$f" != "certs/fullchain.pem" ]; then
                USER_CERT="$f"
                break
            fi
        done
    fi

    # --------------------------------------------------
    # 3b. 根据检测结果处理证书
    # --------------------------------------------------
    if [ -n "$USER_KEY" ] && [ -n "$USER_CERT" ]; then
        # --- 用户上传了证书 ---
        echo "  ✅ 检测到用户提供的证书:"
        echo "     私钥:   $USER_KEY"
        echo "     证书:   $USER_CERT"
        echo ""

        # 验证私钥格式
        if grep -q "BEGIN.*PRIVATE KEY" "$USER_KEY" 2>/dev/null; then
            echo "  ✓ 私钥格式验证通过"
        else
            echo "  ❌ 错误: $USER_KEY 不是有效的 PEM 格式私钥文件"
            echo "     私钥文件应以 '-----BEGIN PRIVATE KEY-----' 或 '-----BEGIN RSA PRIVATE KEY-----' 开头"
            exit 1
        fi

        # 验证证书格式
        if grep -q "BEGIN CERTIFICATE" "$USER_CERT" 2>/dev/null; then
            echo "  ✓ 证书格式验证通过"
        else
            echo "  ❌ 错误: $USER_CERT 不是有效的 PEM 格式证书文件"
            echo "     证书文件应以 '-----BEGIN CERTIFICATE-----' 开头"
            exit 1
        fi

        # 验证私钥和证书是否匹配 (比对 modulus, 通过 alpine/openssl 容器执行)
        KEY_MODULUS=$(run_openssl rsa -noout -modulus -in "$(basename "$USER_KEY")" 2>/dev/null | md5sum 2>/dev/null || echo "unknown")
        CERT_MODULUS=$(run_openssl x509 -noout -modulus -in "$(basename "$USER_CERT")" 2>/dev/null | md5sum 2>/dev/null || echo "unknown")
        if [ "$KEY_MODULUS" != "unknown" ] && [ "$CERT_MODULUS" != "unknown" ] && [ "$KEY_MODULUS" = "$CERT_MODULUS" ]; then
            echo "  ✓ 私钥与证书匹配验证通过"
        elif [ "$KEY_MODULUS" != "unknown" ] && [ "$CERT_MODULUS" != "unknown" ]; then
            echo "  ⚠️  警告: 私钥与证书的 modulus 不匹配, 请检查是否配对"
            echo "     私钥 modulus: $KEY_MODULUS"
            echo "     证书 modulus: $CERT_MODULUS"
        else
            echo "  ⚠️  无法验证私钥与证书是否匹配 (alpine/openssl 镜像拉取失败?), 跳过"
        fi

        # 检查证书是否即将过期 (30天内)
        EXPIRY=$(run_openssl x509 -enddate -noout -in "$(basename "$USER_CERT")" 2>/dev/null | cut -d= -f2)
        if [ -n "$EXPIRY" ]; then
            EXPIRY_EPOCH=$(date -d "$EXPIRY" +%s 2>/dev/null || echo 0)
            NOW_EPOCH=$(date +%s)
            DAYS_LEFT=$(( (EXPIRY_EPOCH - NOW_EPOCH) / 86400 ))
            if [ "$DAYS_LEFT" -lt 0 ]; then
                echo "  ❌ 错误: 证书已过期! (过期日期: $EXPIRY)"
                exit 1
            elif [ "$DAYS_LEFT" -lt 30 ]; then
                echo "  ⚠️  警告: 证书将在 $DAYS_LEFT 天后过期 ($EXPIRY)"
            else
                echo "  ✓ 证书有效期至: $EXPIRY (剩余 $DAYS_LEFT 天)"
            fi
        fi

        # 创建软链接, 让 nginx 使用标准文件名
        # 如果已存在同名文件则跳过
        if [ "$USER_KEY" != "certs/privkey.pem" ]; then
            ln -sf "$(basename "$USER_KEY")" certs/privkey.pem
            echo "  → 已链接: certs/privkey.pem -> $(basename "$USER_KEY")"
        fi
        if [ "$USER_CERT" != "certs/fullchain.pem" ]; then
            ln -sf "$(basename "$USER_CERT")" certs/fullchain.pem
            echo "  → 已链接: certs/fullchain.pem -> $(basename "$USER_CERT")"
        fi

    elif [ -n "$USER_KEY" ] && [ -z "$USER_CERT" ]; then
        echo "  ❌ 错误: 在 certs/ 中找到了私钥文件 ($USER_KEY), 但没有找到证书文件 (.pem/.crt)"
        echo "     请确保证书和私钥都放入 ./certs/ 目录"
        exit 1

    elif [ -z "$USER_KEY" ] && [ -n "$USER_CERT" ]; then
        echo "  ❌ 错误: 在 certs/ 中找到了证书文件 ($USER_CERT), 但没有找到私钥文件 (.key)"
        echo "     请确保证书和私钥都放入 ./certs/ 目录"
        exit 1

    else
        # --- 没有用户证书, 检查是否已有之前生成的 ---
        if [ -f certs/fullchain.pem ] && [ -f certs/privkey.pem ]; then
            echo "  ℹ️  未检测到用户证书, 使用已有的证书文件"
            echo "     证书: certs/fullchain.pem"
            echo "     私钥: certs/privkey.pem"
        else
            # --- 通过 alpine/openssl 容器生成自签名证书 ---
            echo "  ℹ️  未检测到用户证书, 通过 alpine/openssl 容器生成自签名 SSL 证书..."
            run_openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
                -keyout privkey.pem \
                -out fullchain.pem \
                -subj "/CN=${DOMAIN:-localhost}" >/dev/null 2>&1
            echo "  ✓ 自签名证书已生成:"
            echo "     证书: certs/fullchain.pem"
            echo "     私钥: certs/privkey.pem"
            echo "  ⚠️  生产环境请使用 CA 签发的正式证书"
            echo "     将 .key 私钥和 .pem/.crt 证书放入 ./certs/ 目录后重新运行此脚本"
        fi
    fi

    COMPOSE_FILE="docker-compose.https.yml"
    COMPOSE_FILE_FLAG="-f docker-compose.https.yml"
else
    echo "[3/?] HTTP 模式, 跳过证书配置"
    COMPOSE_FILE="docker-compose.yml"
    COMPOSE_FILE_FLAG=""
fi

# ============================================
# 4. 拉取镜像
# ============================================
echo "[4/?] 拉取 Docker 镜像..."
docker compose ${COMPOSE_FILE_FLAG} pull

# ============================================
# 5. 启动服务
# ============================================
echo "[5/?] 启动服务..."
docker compose ${COMPOSE_FILE_FLAG} up -d

echo ""
echo "========================================="
echo "  ✅ 部署完成!"
echo "========================================="
echo ""
if [ "$1" = "--https" ]; then
    echo "  访问地址: https://${DOMAIN:-localhost}:${HTTPS_PORT:-9443}"
    echo "  HTTP 自动重定向到 HTTPS"
else
    echo "  访问地址: http://${DOMAIN:-localhost}:${HTTP_PORT:-9080}"
fi
echo "  用户名:   ${AUTH_USER}"
echo "  密码:     ${AUTH_PASSWORD}"
echo ""
echo "  查看日志:"
if [ "$1" = "--https" ]; then
    echo "    docker compose ${COMPOSE_FILE_FLAG} logs -f"
else
    echo "    docker compose logs -f"
fi
echo ""
echo "  停止服务:"
if [ "$1" = "--https" ]; then
    echo "    docker compose ${COMPOSE_FILE_FLAG} down"
else
    echo "    docker compose down"
fi
echo ""
echo "  修改密码后重新生成 (无需在宿主机安装 htpasswd):"
echo "    docker run --rm --user \"\$(id -u):\$(id -g)\" -v \"\$(pwd)/nginx:/auth\" \\"
echo "      httpd:alpine htpasswd -bcB /auth/.htpasswd <用户名> <密码>"
echo "    docker compose ${COMPOSE_FILE_FLAG} restart nginx"
echo ""
echo "  使用自定义证书:"
echo "    将 .key (私钥) 和 .pem/.crt (证书) 放入 ./certs/ 目录"
echo "    脚本会自动检测并使用你上传的证书"
echo ""
