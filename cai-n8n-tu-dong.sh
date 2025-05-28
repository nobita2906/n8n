#!/bin/bash
set -e

###############################################################################
# Script cài đặt N8N (kèm Postgres, Redis, Docker, SSL, swap v.v.)
# Hỗ trợ cài trên domain chính hoặc subdomain.
###############################################################################

# Kiểm tra quyền root
if [ "$EUID" -ne 0 ]; then
  echo "Vui lòng chạy script với quyền root (sudo)."
  exit 1
fi

###############################################################################
# Kiểm tra RAM VPS
###############################################################################
TOTAL_RAM=$(free -m | awk '/Mem:/ { print $2 }')
if [ "$TOTAL_RAM" -lt 1500 ]; then
  echo "
[Cảnh báo] VPS có RAM thấp (<1.5GB). Khuyên dùng VPS từ 2GB trở lên để tránh treo khi chạy n8n."
fi

###############################################################################
# Thu thập thông tin
###############################################################################
echo "======================================"
echo "  CÀI ĐẶT N8N TỰ ĐỘNG"
echo "======================================"

read -p "Nhập domain chính (VD: cogihay.xyz): " DOMAIN_NAME
read -p "Nhập subdomain (trống để cài trên domain chính): " SUBDOMAIN

HOSTNAME="$DOMAIN_NAME"
[ -n "$SUBDOMAIN" ] && HOSTNAME="${SUBDOMAIN}.${DOMAIN_NAME}"

read -p "Tạo SSL tự động bằng Let's Encrypt? (y/n): " AUTO_SSL
if [[ "$AUTO_SSL" =~ ^[Yy]$ ]]; then
  echo "SSL sẽ được tự động cấp phát bằng Let's Encrypt."
else
  echo "Nhập nội dung SSL CERT (Ctrl+D 2 lần khi xong):"; SSL_CERT_CONTENT="$(</dev/stdin)"
  echo "Nhập nội dung SSL PRIVATE KEY (Ctrl+D 2 lần khi xong):"; SSL_KEY_CONTENT="$(</dev/stdin)"
fi

read -p "Nhập POSTGRES_USER: " POSTGRES_USER
read -s -p "Nhập POSTGRES_PASSWORD: " POSTGRES_PASSWORD; echo
read -p "Nhập POSTGRES_DB: " POSTGRES_DB
read -p "Nhập dung lượng swap (GB): " swap_size

###############################################################################
# Cập nhật, cài gói, Nginx, Redis, Docker, FFmpeg...
###############################################################################
apt update -y && apt upgrade -y
apt install -y curl gnupg2 ca-certificates lsb-release software-properties-common unzip zip ufw sudo

# Cài FFmpeg
add-apt-repository -y ppa:ubuntuhandbook1/ffmpeg7
apt update -y && apt install -y ffmpeg

# Cài Docker
curl -fsSL https://get.docker.com -o get-docker.sh
sh get-docker.sh
usermod -aG docker $USER

# Cài Docker Compose Plugin
apt install -y docker-compose-plugin

# Cài Redis
add-apt-repository -y ppa:redislabs/redis
apt update -y && apt install -y redis-server
systemctl enable redis-server && systemctl start redis-server

# Cài Let's Encrypt (nếu AUTO_SSL)
if [[ "$AUTO_SSL" =~ ^[Yy]$ ]]; then
  apt install -y certbot python3-certbot-nginx
  certbot certonly --nginx -d "$HOSTNAME"
  SSL_CERT_PATH="/etc/letsencrypt/live/$HOSTNAME/fullchain.pem"
  SSL_KEY_PATH="/etc/letsencrypt/live/$HOSTNAME/privkey.pem"
else
  mkdir -p "/etc/nginx/ssl/${HOSTNAME}/"
  echo "$SSL_CERT_CONTENT" > "/etc/nginx/ssl/${HOSTNAME}/certificate.crt"
  echo "$SSL_KEY_CONTENT" > "/etc/nginx/ssl/${HOSTNAME}/private.key"
  SSL_CERT_PATH="/etc/nginx/ssl/${HOSTNAME}/certificate.crt"
  SSL_KEY_PATH="/etc/nginx/ssl/${HOSTNAME}/private.key"
fi

###############################################################################
# Tạo swap
###############################################################################
swapoff /swapfile || true
fallocate -l "${swap_size}G" /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
[[ $(grep -c "/swapfile" /etc/fstab) -eq 0 ]] && echo '/swapfile none swap sw 0 0' >> /etc/fstab

###############################################################################
# Thiết lập Docker Compose file cả n8n, postgres, redis
###############################################################################
INSTALL_DIR="/opt/n8n/${HOSTNAME}"
mkdir -p "$INSTALL_DIR" && cd "$INSTALL_DIR"

# .env
cat > .env <<EOF
HOSTNAME=${HOSTNAME}
POSTGRES_USER=${POSTGRES_USER}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
POSTGRES_DB=${POSTGRES_DB}
EOF
chmod 600 .env

# docker-compose.yml
cat > docker-compose.yml <<EOF
version: '3.7'
services:
  postgres:
    image: postgres:latest
    environment:
      POSTGRES_USER: \${POSTGRES_USER}
      POSTGRES_PASSWORD: \${POSTGRES_PASSWORD}
      POSTGRES_DB: \${POSTGRES_DB}
    volumes:
      - ./postgres:/var/lib/postgresql/data
    ports:
      - "5432:5432"

  redis:
    image: redis:latest
    ports:
      - "6379:6379"
    restart: unless-stopped

  n8n:
    image: n8nio/n8n:latest
    restart: always
    ports:
      - "5678:5678"
    env_file:
      - .env
    environment:
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=postgres
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_DATABASE=\${POSTGRES_DB}
      - DB_POSTGRESDB_USER=\${POSTGRES_USER}
      - DB_POSTGRESDB_PASSWORD=\${POSTGRES_PASSWORD}
      - REDIS_HOST=redis
      - N8N_BASIC_AUTH_ACTIVE=true
      - N8N_BASIC_AUTH_USER=admin
      - N8N_BASIC_AUTH_PASSWORD=admin123
    depends_on:
      - postgres
      - redis
    volumes:
      - ./n8n:/home/node/.n8n
EOF

# Khởi động Docker
docker compose pull
chown -R 1000:1000 $INSTALL_DIR/* || true
docker compose up -d

###############################################################################
echo "
[CÀI ĐẶT HOÀN TẤT] n8n đang chạy tại: https://${HOSTNAME}:5678"
echo "Dùng tài khoản admin/admin123 để đăng nhập. Hãy đổi ngay sau khi login."
