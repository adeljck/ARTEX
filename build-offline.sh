#!/usr/bin/env bash
# ARTEX 离线安装包构建脚本
#
# 用法：
#   ./build-offline.sh [镜像名] [tag] [包名]
#     ./build-offline.sh                          # 默认 artex:0.1.0
#     ./build-offline.sh artex 0.1.0              # 指定 tag
#     ./build-offline.sh myrepo/artex v0.1.0      # 自定义镜像名 + tag（版本戳自动去前导 v）
#     ./build-offline.sh artex 0.1.0 my-pkg       # 自定义安装包名
#
# 环境变量：
#   KEEP_ARTIFACTS=1   保留构建中间产物（dist / web/out / server/webui/dist 等），默认删除
#
# 产出：<包名>.tar.gz，内含 images/*.tar + docker-compose.yml + install.sh + .env.example + README.md
set -euo pipefail
cd "$(cd "$(dirname "$0")" && pwd)"

IMAGE_NAME="${1:-artex}"                                   # 镜像名（不含 tag）
TAG="${2:-0.1.0}"                                           # 镜像 tag
PKG_NAME="${3:-${IMAGE_NAME//\//-}-${TAG}-offline}"         # 安装包名（/ 换成 -）
VERSION="${TAG#v}"                                          # 版本戳去掉前导 v（与 build.sh 一致）

FULL_IMAGE="${IMAGE_NAME}:${TAG}"

info(){ printf '\033[36m[*]\033[0m %s\n' "$*"; }
ok(){   printf '\033[32m[+]\033[0m %s\n' "$*"; }
die(){  printf '\033[31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || die "未检测到 docker"
command -v make   >/dev/null 2>&1 || die "未检测到 make"
command -v go     >/dev/null 2>&1 || die "未检测到 go"
command -v npm    >/dev/null 2>&1 || die "未检测到 npm"

info "镜像：${FULL_IMAGE}  版本戳：${VERSION}  包名：${PKG_NAME}"

# 1) 构建镜像（前端静态 + linux 单二进制 + docker build）
info "1/6 构建 ${FULL_IMAGE} 镜像..."
git checkout dev 2>/dev/null || true
make docker VERSION="$VERSION" IMAGE="$FULL_IMAGE"

# 2) 拉取 postgres（整个服务需要）
info "2/6 拉取 postgres:16-alpine..."
docker pull postgres:16-alpine

# 3) 保存镜像到本地
info "3/6 保存镜像..."
rm -rf "$PKG_NAME"
mkdir -p "$PKG_NAME/images"
docker save "$FULL_IMAGE"        -o "$PKG_NAME/images/$(basename "$IMAGE_NAME")-${TAG}.tar"
docker save postgres:16-alpine   -o "$PKG_NAME/images/postgres-16-alpine.tar"

# 4) 生成 docker-compose.yml
info "4/6 生成 docker-compose.yml / install.sh / .env.example / README.md..."
cat > "$PKG_NAME/docker-compose.yml" <<YAML
services:
  postgres:
    image: postgres:16-alpine
    environment:
      POSTGRES_USER: \${POSTGRES_USER:-artex}
      POSTGRES_PASSWORD: \${POSTGRES_PASSWORD:?请在 .env 设置 POSTGRES_PASSWORD}
      POSTGRES_DB: \${POSTGRES_DB:-artex}
    volumes:
      - pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U \${POSTGRES_USER:-artex} -d \${POSTGRES_DB:-artex}"]
      interval: 5s
      timeout: 3s
      retries: 10
    restart: unless-stopped

  artex:
    image: ${FULL_IMAGE}
    depends_on:
      postgres:
        condition: service_healthy
    environment:
      ARTEX_PG_DSN: postgres://\${POSTGRES_USER:-artex}:\${POSTGRES_PASSWORD}@postgres:5432/\${POSTGRES_DB:-artex}?sslmode=disable
      ANTHROPIC_API_KEY: \${ANTHROPIC_API_KEY:-}
      OPENAI_API_KEY: \${OPENAI_API_KEY:-}
    ports:
      - "8787:8787"
      - "127.0.0.1:8788:8788"
    volumes:
      - ./data:/app/data
      - ./skills:/app/skills
    restart: unless-stopped

volumes:
  pgdata:
YAML

cat > "$PKG_NAME/install.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cd "$(cd "$(dirname "$0")" && pwd)"

echo "[1/3] 加载镜像..."
for img in images/*.tar; do
  docker load -i "$img"
done

echo "[2/3] 生成 .env（如不存在）..."
if [ ! -f .env ]; then
  cp .env.example .env
  pw="$(head -c 18 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)"
  sed -i "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=${pw}|" .env
  echo "已生成 .env（POSTGRES_PASSWORD 已随机设置）"
fi

echo "[3/3] 启动服务..."
docker compose up -d
echo "完成 → http://localhost:8787（首次进入 /setup 设置管理员密码）"
SH
chmod +x "$PKG_NAME/install.sh"

cat > "$PKG_NAME/.env.example" <<'ENV'
POSTGRES_USER=artex
POSTGRES_PASSWORD=change-me-please
POSTGRES_DB=artex
ANTHROPIC_API_KEY=
OPENAI_API_KEY=
ENV

cat > "$PKG_NAME/README.md" <<MD
# ARTEX ${TAG} 离线安装包

## 部署
\`\`\`bash
tar xzf ${PKG_NAME}.tar.gz
cd ${PKG_NAME}
./install.sh          # 加载镜像 + 随机生成密码 + 启动
\`\`\`
打开 http://localhost:8787，首次进入 /setup 设置管理员密码。

## 配置
编辑 \`.env\` 可设置数据库密码、LLM key（ANTHROPIC_API_KEY / OPENAI_API_KEY）。
MD

# 5) 打包
info "5/6 打包..."
tar czf "${PKG_NAME}.tar.gz" "$PKG_NAME"

# 6) 清理中间产物
info "6/6 清理中间产物..."
rm -rf "$PKG_NAME"
if [ "${KEEP_ARTIFACTS:-0}" != "1" ]; then
  make clean
fi

ok "完成 → ${PKG_NAME}.tar.gz"
