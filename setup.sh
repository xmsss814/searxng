# setup.sh
# ============================
# SeaxrXNG + Nginx + Basic Auth 一键部署脚本
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
# 1. 安装 htpasswd (如果没有)
# ============================================
if ! command -v htpasswd &> /dev/null; then
    echo "[1/?] 安装 htpasswd 工具..."
    if command -v apt-get &> /dev/null; then
        sudo apt-get update && sudo apt-get install -y apache2-utils
    elif command -v yum &> /dev/null; then
        sudo yum install -y httpd-tools
    elif command -v apk &> /dev/null; then
        apk add apache2-utils
    elif command -v dnf &> /dev/null; then
        sudo dnf install -y httpd-tools
    else
        echo "错误: 无法自动安装 htpasswd, 请手动安装 apache2-utils 或 httpd-tools"
        echo "然后重新运行此脚本"
        exit 1
    fi
else
    echo "[1/?] htpasswd 工具已安装"
fi

# ============================================
# 2. 生成 .htpasswd 文件
# ============================================
echo "[2/?] 生成 Basic Auth 密码文件..."
mkdir -p nginx
htpasswd -bc nginx/.htpasswd "${AUTH_USER}" "${AUTH_PASSWORD}"
chmod 644 nginx/.htpasswd
echo "  用户: ${AUTH_USER}"
echo "  密码文件: nginx/.htpasswd"

# ============================================
# 3. 确保 SearXNG 配置目录存在
# ============================================
echo "[3/?] 创建 SearXNG 配置目录..."
mkdir -p searxng

# ============================================
# 4. 证书处理 (仅 HTTPS 模式)
# ============================================
if [ "$1" = "--https" ]; then
    echo "[4/?] 配置 SSL 证书..."
    mkdir -p certs

    # --------------------------------------------------
    # 4a. 检测用户自己上传的证书
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
    # 4b. 根据检测结果处理证书
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

        # 验证私钥和证书是否匹配 (比对 modulus)
        KEY_MODULUS=$(openssl rsa -noout -modulus -in "$USER_KEY" 2>/dev/null | md5sum 2>/dev/null || echo "unknown")
        CERT_MODULUS=$(openssl x509 -noout -modulus -in "$USER_CERT" 2>/dev/null | md5sum 2>/dev/null || echo "unknown")
        if [ "$KEY_MODULUS" != "unknown" ] && [ "$CERT_MODULUS" != "unknown" ] && [ "$KEY_MODULUS" = "$CERT_MODULUS" ]; then
            echo "  ✓ 私钥与证书匹配验证通过"
        elif [ "$KEY_MODULUS" != "unknown" ] && [ "$CERT_MODULUS" != "unknown" ]; then
            echo "  ⚠️  警告: 私钥与证书的 modulus 不匹配, 请检查是否配对"
            echo "     私钥 modulus: $KEY_MODULUS"
            echo "     证书 modulus: $CERT_MODULUS"
        else
            echo "  ⚠️  无法验证私钥与证书是否匹配 (openssl 不可用?), 跳过"
        fi

        # 检查证书是否即将过期 (30天内)
        if command -v openssl &> /dev/null; then
            EXPIRY=$(openssl x509 -enddate -noout -in "$USER_CERT" 2>/dev/null | cut -d= -f2)
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
            # --- 生成自签名证书 ---
            echo "  ℹ️  未检测到用户证书, 生成自签名 SSL 证书..."
            if command -v openssl &> /dev/null; then
                openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
                    -keyout certs/privkey.pem \
                    -out certs/fullchain.pem \
                    -subj "/CN=${DOMAIN:-localhost}"
                echo "  ✓ 自签名证书已生成:"
                echo "     证书: certs/fullchain.pem"
                echo "     私钥: certs/privkey.pem"
                echo "  ⚠️  生产环境请使用 CA 签发的正式证书"
                echo "     将 .key 私钥和 .pem/.crt 证书放入 ./certs/ 目录后重新运行此脚本"
            else
                echo "  ❌ 错误: 找不到 openssl 命令, 且未提供证书文件"
                echo "     请手动将 .key 和 .pem 文件放入 ./certs/ 目录, 或安装 openssl"
                exit 1
            fi
        fi
    fi

    COMPOSE_FILE="docker-compose.https.yml"
    COMPOSE_FILE_FLAG="-f docker-compose.https.yml"
else
    echo "[4/?] HTTP 模式, 跳过证书配置"
    COMPOSE_FILE="docker-compose.yml"
    COMPOSE_FILE_FLAG=""
fi

# ============================================
# 5. 拉取镜像
# ============================================
echo "[5/?] 拉取 Docker 镜像..."
docker compose ${COMPOSE_FILE_FLAG} pull

# ============================================
# 6. 启动服务
# ============================================
echo "[6/?] 启动服务..."
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
echo "  修改密码后重新生成:"
echo "    编辑 .env 文件, 然后运行: htpasswd -bc nginx/.htpasswd <用户名> <密码>"
echo ""
echo "  使用自定义证书:"
echo "    将 .key (私钥) 和 .pem/.crt (证书) 放入 ./certs/ 目录"
echo "    脚本会自动检测并使用你上传的证书"
echo ""
