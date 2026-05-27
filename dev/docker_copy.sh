#!/usr/bin/env bash
# ============================================================
# One-shot installer (DEV/PROD) - generates all files under BASE_DIR
#
# Usage:
#   sudo ./install_all.sh prod
#   sudo ./install_all.sh dev
#
# Override:
#   sudo BASE_DIR=/opt/llm-stack/deploy ./install_all.sh prod
#   sudo BASE_DIR=/home/pps-nipa/NR/dev/deploy ./install_all.sh dev
#
# Notes:
# - PROD: no host ports exposed (internal-only services)
# - DEV : ports exposed via docker-compose.dev.yml (override)
#
# [SET_ME] After first run, 반드시 .env.* 수정:
# - DOMAIN_EAI / DOMAIN_LLM
# - IMG_* (실제 이미지 태그)
# - 비밀번호/키
# - STT_RESOURCE_DIR_REL (src/resoursces vs src/resources)
# ============================================================

set -Eeuo pipefail

ENV_NAME="${1:-prod}"   # dev|prod
if [[ "${ENV_NAME}" != "dev" && "${ENV_NAME}" != "prod" ]]; then
  echo "[ERROR] env must be dev or prod. ex) sudo ./install_all.sh prod"
  exit 1
fi

BASE_DIR="${BASE_DIR:-/opt/llm-stack/deploy}"
APPLY_FIREWALL="${APPLY_FIREWALL:-1}"           # 0이면 방화벽 스킵
ALLOW_SSH_PORT="${ALLOW_SSH_PORT:-22}"          # SSH 포트(환경 따라 2222 등일 수 있음) [SET_ME]
LE_DIR_DEFAULT="/etc/letsencrypt"
CERTBOT_WEBROOT_DEFAULT="/var/www/certbot"

log()  { echo -e "[INFO] $*"; }
warn() { echo -e "[WARN] $*" >&2; }
die()  { echo -e "[ERROR] $*" >&2; exit 1; }

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Run as root. ex) sudo $0 ${ENV_NAME}"
  fi
}

detect_pkg_mgr() {
  if command -v apt-get >/dev/null 2>&1; then
    echo "apt"; return
  fi
  if command -v dnf >/dev/null 2>&1; then
    echo "dnf"; return
  fi
  if command -v yum >/dev/null 2>&1; then
    echo "yum"; return
  fi
  die "No supported package manager found (apt/dnf/yum)."
}

install_prereqs() {
  local pm="$1"
  log "Installing prerequisites (pm=${pm})..."
  if [[ "${pm}" == "apt" ]]; then
    apt-get update -y
    apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg lsb-release \
      openssl rsync jq \
      iproute2 net-tools \
      ufw \
      || true
  else
    "${pm}" -y install \
      ca-certificates curl openssl rsync jq \
      iproute net-tools \
      firewalld \
      || true
  fi
}

install_docker() {
  if command -v docker >/dev/null 2>&1; then
    log "Docker already installed: $(docker --version)"
    return 0
  fi

  local pm="$1"
  log "Installing Docker Engine..."

  # Most common reliable approach:
  # - Ubuntu/Debian: official docker apt repo
  # - RHEL-like: get.docker.com convenience script (fallback)
  if [[ "${pm}" == "apt" ]]; then
    # Determine distro id for repo path (ubuntu/debian supported)
    local os_id
    os_id="$(. /etc/os-release && echo "${ID}")"
    if [[ "${os_id}" != "ubuntu" && "${os_id}" != "debian" ]]; then
      warn "OS_ID=${os_id} not ubuntu/debian. Falling back to get.docker.com (SET_ME)."
      curl -fsSL https://get.docker.com | sh
    else
      install -m 0755 -d /etc/apt/keyrings
      curl -fsSL "https://download.docker.com/linux/${os_id}/gpg" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
      chmod a+r /etc/apt/keyrings/docker.gpg

      local codename
      codename="$(. /etc/os-release && echo "${VERSION_CODENAME:-$(lsb_release -cs 2>/dev/null || echo stable)}")"

      echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${os_id} \
        ${codename} stable" | tee /etc/apt/sources.list.d/docker.list >/dev/null

      apt-get update -y
      apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    fi
    systemctl enable --now docker
  else
    # RHEL-like
    warn "Using get.docker.com on ${pm} based system (most compatible)."
    curl -fsSL https://get.docker.com | sh
    systemctl enable --now docker || true
    # Compose plugin might not be installed depending on distro repo; verify below.
  fi

  command -v docker >/dev/null 2>&1 || die "Docker install failed."
  if ! docker compose version >/dev/null 2>&1; then
    warn "docker compose plugin not found. Installing docker-compose-plugin if possible (SET_ME)."
    if command -v apt-get >/dev/null 2>&1; then
      apt-get install -y docker-compose-plugin || true
    elif command -v dnf >/dev/null 2>&1; then
      dnf -y install docker-compose-plugin || true
    elif command -v yum >/dev/null 2>&1; then
      yum -y install docker-compose-plugin || true
    fi
  fi
  log "Docker OK: $(docker --version)"
  log "Compose OK: $(docker compose version || echo 'missing (SET_ME)')"
}

make_dirs() {
  log "Creating directory structure: ${BASE_DIR}"
  mkdir -p "${BASE_DIR}/nginx/tls"
  mkdir -p "${BASE_DIR}/redis/sentinel"
}

# helper: read key from env file
env_get() {
  local file="$1" key="$2"
  grep -E "^${key}=" "${file}" | head -n1 | sed -E "s/^${key}=//"
}

write_env_file_if_missing() {
  local envfile="${BASE_DIR}/.env.${ENV_NAME}"
  if [[ -f "${envfile}" ]]; then
    warn "${envfile} exists. Keeping it."
    return 0
  fi

  log "Creating ${envfile} (placeholders included) ..."
  if [[ "${ENV_NAME}" == "prod" ]]; then
    cat > "${envfile}" <<EOF
ENV_NAME=prod
LE_DIR=${LE_DIR_DEFAULT}
CERTBOT_WEBROOT=${CERTBOT_WEBROOT_DEFAULT}

# [SET_ME] 실제 도메인
DOMAIN_EAI=eai.example.com
DOMAIN_LLM=llm.example.com

# ===== images (SET_ME: 실제 레지스트리/태그) =====
IMG_BACKEND=your-org/spring-boot-backend:prod
IMG_STT_WORKER=your-org/stt-worker:prod
IMG_LLM_WORKER=your-org/llm-worker:prod
IMG_OCR_API=your-org/ocr-api:prod
IMG_OCR_WORKER=your-org/ocr-worker:prod
IMG_LLM_API=your-org/llm-api:prod

IMG_MIC_SR=your-org/mic-speech-recognize:prod
IMG_SPEECH_SR=your-org/speech-recognize:prod
IMG_STT_API=your-org/stt-api:prod

# internal endpoints
MIC_SR_BASE=http://mic_speech_recognize:8017
SPEECH_SR_BASE=http://speech_recognize:8016
STT_API_BASE=http://stt_api:8000
LLM_API_BASE=http://llm_api:8080
OCR_API_BASE=http://ocr_api:8080

# STT runtime
# [SET_ME] src/resoursces 또는 src/resources
STT_RESOURCE_DIR_REL=src/resources
SPEAKER_MODEL_REL=models/iic/speech_eres2net_base_sv_zh-cn_3dspeaker_16k
MIC_INPUT_DATA_REL=test/input_Data
MIC_SERVICE_PORT=8017
SPEECH_SERVICE_PORT=8016
STT_SERVICE_PORT=8000

# OCR/LLM namespace
TENANT_ID=tenant-default
DOC_NAMESPACE_PREFIX=docs
SEARCH_INDEX_PREFIX=rag
EMBEDDING_MODEL_ID=text-embedding-xxx  # [SET_ME]

OCR_INPUT_BUCKET=uploads
OCR_OUTPUT_BUCKET=parsed

# credentials [SET_ME]
MARIADB_ROOT_PASSWORD=ChangeMeRoot_PROD
BIZ_DB_USER=bizuser
BIZ_DB_PASSWORD=ChangeMeBiz_PROD
LOG_DB_USER=loguser
LOG_DB_PASSWORD=ChangeMeLog_PROD

MINIO_ROOT_USER=minio
MINIO_ROOT_PASSWORD=ChangeMeMinio_PROD

NEO4J_USER=neo4j
NEO4J_PASSWORD=ChangeMeNeo4j_PROD
EOF
  else
    cat > "${envfile}" <<EOF
ENV_NAME=dev
LE_DIR=${LE_DIR_DEFAULT}
CERTBOT_WEBROOT=${CERTBOT_WEBROOT_DEFAULT}

# [SET_ME] dev 도메인/hosts 매핑 필요 가능
DOMAIN_EAI=eai.dev.local
DOMAIN_LLM=llm.dev.local

IMG_BACKEND=your-org/spring-boot-backend:dev
IMG_STT_WORKER=your-org/stt-worker:dev
IMG_LLM_WORKER=your-org/llm-worker:dev
IMG_OCR_API=your-org/ocr-api:dev
IMG_OCR_WORKER=your-org/ocr-worker:dev
IMG_LLM_API=your-org/llm-api:dev

IMG_MIC_SR=your-org/mic-speech-recognize:dev
IMG_SPEECH_SR=your-org/speech-recognize:dev
IMG_STT_API=your-org/stt-api:dev

MIC_SR_BASE=http://mic_speech_recognize:8017
SPEECH_SR_BASE=http://speech_recognize:8016
STT_API_BASE=http://stt_api:8000
LLM_API_BASE=http://llm_api:8080
OCR_API_BASE=http://ocr_api:8080

# DEV 기본값(오타 가능성 방지용) - 실제 폴더명으로 수정 [SET_ME]
STT_RESOURCE_DIR_REL=src/resoursces
SPEAKER_MODEL_REL=models/iic/speech_eres2net_base_sv_zh-cn_3dspeaker_16k
MIC_INPUT_DATA_REL=test/input_Data
MIC_SERVICE_PORT=8017
SPEECH_SERVICE_PORT=8016
STT_SERVICE_PORT=8000

TENANT_ID=tenant-default
DOC_NAMESPACE_PREFIX=docs
SEARCH_INDEX_PREFIX=rag
EMBEDDING_MODEL_ID=text-embedding-xxx

OCR_INPUT_BUCKET=uploads
OCR_OUTPUT_BUCKET=parsed

MARIADB_ROOT_PASSWORD=ChangeMeRoot_DEV
BIZ_DB_USER=bizuser
BIZ_DB_PASSWORD=ChangeMeBiz_DEV
LOG_DB_USER=loguser
LOG_DB_PASSWORD=ChangeMeLog_DEV

MINIO_ROOT_USER=minio
MINIO_ROOT_PASSWORD=ChangeMeMinio_DEV

NEO4J_USER=neo4j
NEO4J_PASSWORD=ChangeMeNeo4j_DEV
EOF
  fi

  log "Created ${envfile}"
  warn "[SET_ME] ${envfile}의 IMG_*/DOMAIN_*/비밀번호를 실제 값으로 수정 필요"
}

ensure_selfsigned_tls() {
  local crt="${BASE_DIR}/nginx/tls/selfsigned.crt"
  local key="${BASE_DIR}/nginx/tls/selfsigned.key"
  if [[ -f "${crt}" && -f "${key}" ]]; then
    return 0
  fi
  log "Generating self-signed TLS cert (fallback)..."
  openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
    -subj "/CN=local-selfsigned" \
    -keyout "${key}" -out "${crt}" >/dev/null 2>&1 || die "openssl failed"
  chmod 600 "${key}"
}

write_nginx_tls_conf() {
  cat > "${BASE_DIR}/nginx/tls/tls.conf" <<'EOF'
ssl_protocols TLSv1.2 TLSv1.3;
ssl_prefer_server_ciphers off;

ssl_stapling on;
ssl_stapling_verify on;

add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
EOF
}

write_nginx_confs() {
  local envfile="${BASE_DIR}/.env.${ENV_NAME}"
  local domain_eai domain_llm le_dir webroot

  domain_eai="$(env_get "${envfile}" "DOMAIN_EAI")"
  domain_llm="$(env_get "${envfile}" "DOMAIN_LLM")"
  le_dir="$(env_get "${envfile}" "LE_DIR")"
  webroot="$(env_get "${envfile}" "CERTBOT_WEBROOT")"

  [[ -n "${domain_eai}" ]] || die "DOMAIN_EAI missing in ${envfile}"
  [[ -n "${domain_llm}" ]] || die "DOMAIN_LLM missing in ${envfile}"
  [[ -n "${le_dir}" ]] || le_dir="${LE_DIR_DEFAULT}"
  [[ -n "${webroot}" ]] || webroot="${CERTBOT_WEBROOT_DEFAULT}"

  mkdir -p "${webroot}" || true
  ensure_selfsigned_tls
  write_nginx_tls_conf

  # LE cert가 없으면 self-signed 사용(nginx 부팅 우선)
  local eai_fullchain="${le_dir}/live/${domain_eai}/fullchain.pem"
  local eai_privkey="${le_dir}/live/${domain_eai}/privkey.pem"
  local llm_fullchain="${le_dir}/live/${domain_llm}/fullchain.pem"
  local llm_privkey="${le_dir}/live/${domain_llm}/privkey.pem"

  local eai_crt eai_key llm_crt llm_key
  if [[ -f "${eai_fullchain}" && -f "${eai_privkey}" ]]; then
    eai_crt="${eai_fullchain}"; eai_key="${eai_privkey}"
  else
    warn "EAI cert not found -> using self-signed (SET_ME)"
    eai_crt="/etc/nginx/tls/selfsigned.crt"; eai_key="/etc/nginx/tls/selfsigned.key"
  fi
  if [[ -f "${llm_fullchain}" && -f "${llm_privkey}" ]]; then
    llm_crt="${llm_fullchain}"; llm_key="${llm_privkey}"
  else
    warn "LLM cert not found -> using self-signed (SET_ME)"
    llm_crt="/etc/nginx/tls/selfsigned.crt"; llm_key="/etc/nginx/tls/selfsigned.key"
  fi

  # IMPORTANT: nginx conf에는 ${DOMAIN_*} 같은 env placeholder를 넣지 않음(확장 안됨)
  cat > "${BASE_DIR}/nginx/eai.conf" <<EOF
server {
  listen 80;
  server_name ${domain_eai};

  location /.well-known/acme-challenge/ {
    root ${webroot};
  }

  location / { return 301 https://\$host\$request_uri; }
}

server {
  listen 443 ssl http2;
  server_name ${domain_eai};

  include /etc/nginx/tls/tls.conf;

  ssl_certificate     ${eai_crt};
  ssl_certificate_key ${eai_key};

  location / {
    proxy_pass http://backend:8080;
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-Proto https;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Real-IP \$remote_addr;
  }
}
EOF

  cat > "${BASE_DIR}/nginx/llm.conf" <<EOF
server {
  listen 80;
  server_name ${domain_llm};

  location /.well-known/acme-challenge/ {
    root ${webroot};
  }

  location / { return 301 https://\$host\$request_uri; }
}

server {
  listen 443 ssl http2;
  server_name ${domain_llm};

  include /etc/nginx/tls/tls.conf;

  ssl_certificate     ${llm_crt};
  ssl_certificate_key ${llm_key};

  location / {
    proxy_pass http://llm_api:8080;
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-Proto https;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Real-IP \$remote_addr;
  }
}
EOF
}

write_redis_sentinel_confs() {
  for i in 1 2 3; do
    cat > "${BASE_DIR}/redis/sentinel/sentinel-${i}.conf" <<'EOF'
port 26379
dir /tmp

sentinel monitor mymaster redis_master 6379 2
sentinel down-after-milliseconds mymaster 5000
sentinel failover-timeout mymaster 10000
sentinel parallel-syncs mymaster 1

# [SET_ME] Redis AUTH 사용 시:
# sentinel auth-pass mymaster <password>
EOF
  done
}

write_compose_files() {
  local compose="${BASE_DIR}/docker-compose.yml"
  local compose_dev="${BASE_DIR}/docker-compose.dev.yml"

  if [[ ! -f "${compose}" ]]; then
    cat > "${compose}" <<'EOF'
version: "3.9"

networks:
  app_net: { driver: bridge }
  data_net: { driver: bridge }

volumes:
  mariadb_primary_data: {}
  mariadb_replica_data: {}
  mariadb_log_data: {}
  redis_master_data: {}
  redis_replica_1_data: {}
  redis_replica_2_data: {}
  minio_data: {}
  es_data: {}

services:
  ingress_eai:
    image: nginx:alpine
    container_name: ingress_eai
    network_mode: "host"
    volumes:
      - ./nginx/eai.conf:/etc/nginx/conf.d/default.conf:ro
      - ./nginx/tls/tls.conf:/etc/nginx/tls/tls.conf:ro
      - ./nginx/tls/selfsigned.crt:/etc/nginx/tls/selfsigned.crt:ro
      - ./nginx/tls/selfsigned.key:/etc/nginx/tls/selfsigned.key:ro
      - ${LE_DIR}:${LE_DIR}:ro
      - ${CERTBOT_WEBROOT}:${CERTBOT_WEBROOT}:ro
    restart: unless-stopped

  ingress_llm:
    image: nginx:alpine
    container_name: ingress_llm
    network_mode: "host"
    volumes:
      - ./nginx/llm.conf:/etc/nginx/conf.d/default.conf:ro
      - ./nginx/tls/tls.conf:/etc/nginx/tls/tls.conf:ro
      - ./nginx/tls/selfsigned.crt:/etc/nginx/tls/selfsigned.crt:ro
      - ./nginx/tls/selfsigned.key:/etc/nginx/tls/selfsigned.key:ro
      - ${LE_DIR}:${LE_DIR}:ro
      - ${CERTBOT_WEBROOT}:${CERTBOT_WEBROOT}:ro
    restart: unless-stopped

  backend:
    image: ${IMG_BACKEND}
    container_name: backend
    environment:
      MIC_SR_BASE: "${MIC_SR_BASE}"
      SPEECH_SR_BASE: "${SPEECH_SR_BASE}"
      STT_API_BASE: "${STT_API_BASE}"
      LLM_API_BASE: "${LLM_API_BASE}"
      OCR_API_BASE: "${OCR_API_BASE}"

      BIZ_DB_HOST: mariadb_primary
      LOG_DB_HOST: mariadb_log
      REDIS_SENTINELS: "redis_sentinel_1:26379,redis_sentinel_2:26379,redis_sentinel_3:26379"
      REDIS_MASTER_NAME: "mymaster"
      MINIO_ENDPOINT: "http://minio:9000"
    depends_on:
      - mariadb_primary
      - mariadb_log
      - redis_sentinel_1
      - minio
      - mic_speech_recognize
      - speech_recognize
      - stt_api
      - ocr_api
      - llm_api
    networks: [app_net, data_net]
    restart: unless-stopped

  # STT/Speaker (PROD: ports 없음)
  mic_speech_recognize:
    image: ${IMG_MIC_SR}
    container_name: mic_speech_recognize
    environment:
      APP_ROOT: "/app"
      PYTHONPATH: "/app"
      RESOURCE_DIR_REL: "${STT_RESOURCE_DIR_REL}"
      SPEAKER_MODEL_REL: "${SPEAKER_MODEL_REL}"
      INPUT_DATA_REL: "${MIC_INPUT_DATA_REL}"
      SERVICE_PORT: "${MIC_SERVICE_PORT}"
    networks: [app_net, data_net]
    restart: unless-stopped

  speech_recognize:
    image: ${IMG_SPEECH_SR}
    container_name: speech_recognize
    environment:
      APP_ROOT: "/app"
      PYTHONPATH: "/app"
      RESOURCE_DIR_REL: "${STT_RESOURCE_DIR_REL}"
      SPEAKER_MODEL_REL: "${SPEAKER_MODEL_REL}"
      SERVICE_PORT: "${SPEECH_SERVICE_PORT}"
    networks: [app_net, data_net]
    restart: unless-stopped

  stt_api:
    image: ${IMG_STT_API}
    container_name: stt_api
    environment:
      APP_ROOT: "/app"
      PYTHONPATH: "/app"
      SERVICE_PORT: "${STT_SERVICE_PORT}"
    networks: [app_net, data_net]
    restart: unless-stopped

  stt_worker:
    image: ${IMG_STT_WORKER}
    container_name: stt_worker
    environment:
      REDIS_SENTINELS: "redis_sentinel_1:26379,redis_sentinel_2:26379,redis_sentinel_3:26379"
      REDIS_MASTER_NAME: "mymaster"
    depends_on: [redis_sentinel_1]
    networks: [app_net, data_net]
    restart: unless-stopped

  llm_worker:
    image: ${IMG_LLM_WORKER}
    container_name: llm_worker
    environment:
      REDIS_SENTINELS: "redis_sentinel_1:26379,redis_sentinel_2:26379,redis_sentinel_3:26379"
      REDIS_MASTER_NAME: "mymaster"
      LLM_API_BASE: "${LLM_API_BASE}"
    depends_on: [redis_sentinel_1, llm_api]
    networks: [app_net, data_net]
    restart: unless-stopped

  ocr_api:
    image: ${IMG_OCR_API}
    container_name: ocr_api
    environment:
      MINIO_ENDPOINT: "http://minio:9000"
      REDIS_SENTINELS: "redis_sentinel_1:26379,redis_sentinel_2:26379,redis_sentinel_3:26379"
      REDIS_MASTER_NAME: "mymaster"
      OCR_QUEUE_KEY: "q:ocr:jobs"
    depends_on: [minio, redis_sentinel_1]
    networks: [app_net, data_net]
    restart: unless-stopped

  # OCR worker가 chunking/embedding 주체
  ocr_worker:
    image: ${IMG_OCR_WORKER}
    container_name: ocr_worker
    environment:
      MINIO_ENDPOINT: "http://minio:9000"
      OCR_INPUT_BUCKET: "${OCR_INPUT_BUCKET}"
      OCR_OUTPUT_BUCKET: "${OCR_OUTPUT_BUCKET}"
      LOG_DB_HOST: mariadb_log

      TENANT_ID: "${TENANT_ID}"
      DOC_NAMESPACE_PREFIX: "${DOC_NAMESPACE_PREFIX}"
      SEARCH_INDEX_PREFIX: "${SEARCH_INDEX_PREFIX}"
      EMBEDDING_MODEL_ID: "${EMBEDDING_MODEL_ID}"

      VECTOR_DB_HOST: vector_db
      GRAPH_DB_HOST: graph_db

      REDIS_SENTINELS: "redis_sentinel_1:26379,redis_sentinel_2:26379,redis_sentinel_3:26379"
      REDIS_MASTER_NAME: "mymaster"
      OCR_QUEUE_KEY: "q:ocr:jobs"
    depends_on: [ocr_api, minio, mariadb_log, vector_db, graph_db, redis_sentinel_1]
    networks: [app_net, data_net]
    restart: unless-stopped

  llm_api:
    image: ${IMG_LLM_API}
    container_name: llm_api
    environment:
      VECTOR_DB_HOST: vector_db
      GRAPH_DB_HOST: graph_db
      ELASTICSEARCH_HOST: elasticsearch

      TENANT_ID: "${TENANT_ID}"
      DOC_NAMESPACE_PREFIX: "${DOC_NAMESPACE_PREFIX}"
      SEARCH_INDEX_PREFIX: "${SEARCH_INDEX_PREFIX}"

      REDIS_SENTINELS: "redis_sentinel_1:26379,redis_sentinel_2:26379,redis_sentinel_3:26379"
      REDIS_MASTER_NAME: "mymaster"
    depends_on: [vector_db, graph_db, elasticsearch, redis_sentinel_1]
    networks: [app_net, data_net]
    restart: unless-stopped

  # DATA (PROD: ports 없음)
  mariadb_primary:
    image: mariadb:11
    container_name: mariadb_primary
    environment:
      MARIADB_ROOT_PASSWORD: ${MARIADB_ROOT_PASSWORD}
      MARIADB_DATABASE: biz
      MARIADB_USER: ${BIZ_DB_USER}
      MARIADB_PASSWORD: ${BIZ_DB_PASSWORD}
    volumes:
      - mariadb_primary_data:/var/lib/mysql
    networks: [data_net]
    restart: unless-stopped

  mariadb_replica:
    image: mariadb:11
    container_name: mariadb_replica
    environment:
      MARIADB_ROOT_PASSWORD: ${MARIADB_ROOT_PASSWORD}
    volumes:
      - mariadb_replica_data:/var/lib/mysql
    depends_on: [mariadb_primary]
    networks: [data_net]
    restart: unless-stopped

  mariadb_log:
    image: mariadb:11
    container_name: mariadb_log
    environment:
      MARIADB_ROOT_PASSWORD: ${MARIADB_ROOT_PASSWORD}
      MARIADB_DATABASE: log
      MARIADB_USER: ${LOG_DB_USER}
      MARIADB_PASSWORD: ${LOG_DB_PASSWORD}
    volumes:
      - mariadb_log_data:/var/lib/mysql
    networks: [data_net]
    restart: unless-stopped

  redis_master:
    image: redis:7-alpine
    container_name: redis_master
    command: ["redis-server","--appendonly","yes"]
    volumes: [ redis_master_data:/data ]
    networks: [data_net]
    restart: unless-stopped

  redis_replica_1:
    image: redis:7-alpine
    container_name: redis_replica_1
    command: ["redis-server","--replicaof","redis_master","6379","--appendonly","yes"]
    volumes: [ redis_replica_1_data:/data ]
    depends_on: [redis_master]
    networks: [data_net]
    restart: unless-stopped

  redis_replica_2:
    image: redis:7-alpine
    container_name: redis_replica_2
    command: ["redis-server","--replicaof","redis_master","6379","--appendonly","yes"]
    volumes: [ redis_replica_2_data:/data ]
    depends_on: [redis_master]
    networks: [data_net]
    restart: unless-stopped

  redis_sentinel_1:
    image: redis:7-alpine
    container_name: redis_sentinel_1
    command: ["redis-sentinel","/etc/redis/sentinel.conf"]
    volumes: [ "./redis/sentinel/sentinel-1.conf:/etc/redis/sentinel.conf:ro" ]
    depends_on: [redis_master, redis_replica_1, redis_replica_2]
    networks: [data_net]
    restart: unless-stopped

  redis_sentinel_2:
    image: redis:7-alpine
    container_name: redis_sentinel_2
    command: ["redis-sentinel","/etc/redis/sentinel.conf"]
    volumes: [ "./redis/sentinel/sentinel-2.conf:/etc/redis/sentinel.conf:ro" ]
    depends_on: [redis_master, redis_replica_1, redis_replica_2]
    networks: [data_net]
    restart: unless-stopped

  redis_sentinel_3:
    image: redis:7-alpine
    container_name: redis_sentinel_3
    command: ["redis-sentinel","/etc/redis/sentinel.conf"]
    volumes: [ "./redis/sentinel/sentinel-3.conf:/etc/redis/sentinel.conf:ro" ]
    depends_on: [redis_master, redis_replica_1, redis_replica_2]
    networks: [data_net]
    restart: unless-stopped

  minio:
    image: minio/minio:latest
    container_name: minio
    command: ["server","/data","--console-address",":9001"]
    environment:
      MINIO_ROOT_USER: ${MINIO_ROOT_USER}
      MINIO_ROOT_PASSWORD: ${MINIO_ROOT_PASSWORD}
    volumes: [ minio_data:/data ]
    networks: [data_net]
    restart: unless-stopped

  vector_db:
    image: qdrant/qdrant:latest
    container_name: vector_db
    networks: [data_net]
    restart: unless-stopped

  graph_db:
    image: neo4j:5
    container_name: graph_db
    environment:
      NEO4J_AUTH: ${NEO4J_USER}/${NEO4J_PASSWORD}
    networks: [data_net]
    restart: unless-stopped

  elasticsearch:
    image: docker.elastic.co/elasticsearch/elasticsearch:8.13.0
    container_name: elasticsearch
    environment:
      - discovery.type=single-node
      - xpack.security.enabled=false
      - ES_JAVA_OPTS=-Xms1g -Xmx1g
    volumes: [ es_data:/usr/share/elasticsearch/data ]
    networks: [data_net]
    restart: unless-stopped
EOF
  fi

  if [[ ! -f "${compose_dev}" ]]; then
    cat > "${compose_dev}" <<'EOF'
version: "3.9"
services:
  # DEV only: 외부 통신 허용
  mic_speech_recognize:
    ports: ["8017:8017"]
  speech_recognize:
    ports: ["8016:8016"]
  stt_api:
    ports: ["8000:8000"]

  minio:
    ports: ["9000:9000","9001:9001"]
  vector_db:
    ports: ["6333:6333"]
  graph_db:
    ports: ["7474:7474","7687:7687"]
  elasticsearch:
    ports: ["9200:9200"]

  # 필요 시 DEV에서만
  mariadb_primary:
    ports: ["3306:3306"]
  mariadb_log:
    ports: ["3307:3306"]
EOF
  fi
}

apply_firewall_rules() {
  if [[ "${APPLY_FIREWALL}" != "1" ]]; then
    warn "Firewall skipped (APPLY_FIREWALL=0)."
    return 0
  fi

  # 방화벽은 서버 접근 끊길 수 있으니 SSH 먼저 오픈
  if command -v ufw >/dev/null 2>&1; then
    log "Configuring UFW..."
    ufw --force enable || true
    ufw default deny incoming || true
    ufw default allow outgoing || true

    ufw allow "${ALLOW_SSH_PORT}/tcp" || true
    ufw allow 80/tcp || true
    ufw allow 443/tcp || true

    warn "VRRP(keepalived) 사용 시 protocol 112(vrrp) 허용 필요 (SET_ME)"

    if [[ "${ENV_NAME}" == "dev" ]]; then
      for p in 8000 8016 8017 9000 9001 9200 6333 7474 7687 3306 3307; do
        ufw allow "${p}/tcp" || true
      done
    fi
    ufw status verbose || true
    return 0
  fi

  if command -v firewall-cmd >/dev/null 2>&1; then
    log "Configuring firewalld..."
    systemctl enable --now firewalld || true
    firewall-cmd --permanent --add-service=ssh || true
    firewall-cmd --permanent --add-service=http || true
    firewall-cmd --permanent --add-service=https || true

    warn "VRRP(keepalived) 사용 시 vrrp(112) 허용 필요 (SET_ME)"

    if [[ "${ENV_NAME}" == "dev" ]]; then
      for p in 8000 8016 8017 9000 9001 9200 6333 7474 7687 3306 3307; do
        firewall-cmd --permanent --add-port="${p}/tcp" || true
      done
    fi

    firewall-cmd --reload || true
    firewall-cmd --list-all || true
    return 0
  fi

  warn "No ufw/firewalld detected. Firewall not applied."
}

compose_up() {
  local envfile="${BASE_DIR}/.env.${ENV_NAME}"
  [[ -f "${envfile}" ]] || die "Missing ${envfile}"

  pushd "${BASE_DIR}" >/dev/null
  if [[ "${ENV_NAME}" == "dev" ]]; then
    docker compose --env-file ".env.dev" -f docker-compose.yml -f docker-compose.dev.yml up -d
  else
    docker compose --env-file ".env.prod" -f docker-compose.yml up -d
  fi
  docker compose ps || true
  popd >/dev/null
}

write_ops_md() {
  local md="${BASE_DIR}/OPS_DELIVERY_SPEC.md"
  if [[ -f "${md}" ]]; then
    warn "${md} exists. Keeping it."
    return 0
  fi
  cat > "${md}" <<'EOF'
(위에 제공한 OPS_DELIVERY_SPEC.md 내용을 그대로 붙여 넣으세요)
EOF
  warn "[SET_ME] OPS_DELIVERY_SPEC.md는 현재 placeholder. 위 md 본문을 복붙해서 완성하세요."
}

main() {
  require_root
  local pm
  pm="$(detect_pkg_mgr)"

  install_prereqs "${pm}"
  install_docker "${pm}"

  make_dirs
  write_env_file_if_missing
  write_redis_sentinel_confs
  write_compose_files
  write_nginx_confs
  write_ops_md

  apply_firewall_rules
  compose_up

  log "DONE: generated files under ${BASE_DIR}"
  warn "[SET_ME] 반드시 ${BASE_DIR}/.env.${ENV_NAME} 수정 후 재기동 필요할 수 있음"
  warn "  ex) docker compose --env-file .env.${ENV_NAME} -f docker-compose.yml (and dev override) up -d"
}

main "$@"