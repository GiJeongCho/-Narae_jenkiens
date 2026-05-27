#!/usr/bin/env bash
# ============================================================
# One-shot installer - generates all files under BASE_DIR
#
# Usage:
#   sudo ./docker.sh dev                  # 전체 서비스 기동
#   sudo ./docker.sh dev up               # 전체 서비스 기동 (동일)
#   sudo ./docker.sh dev up backend       # backend만 기동
#   sudo ./docker.sh dev up stt_api milvus  # 특정 서비스만 기동
#   sudo ./docker.sh dev down             # 전체 서비스 중지
#   sudo ./docker.sh dev ps               # 서비스 상태 확인
#   sudo ./docker.sh dev logs backend     # 특정 서비스 로그
#   sudo ./docker.sh dev restart backend  # 특정 서비스 재시작
#   sudo ./docker.sh dev list             # 사용 가능한 서비스 목록
#
# Override:
#   sudo BASE_DIR=/home/pps-nipa/jenkins/dev/deploy ./docker.sh dev
#
# 포트 규칙:
#   dev = 6000번대 | stg = 9000번대 | prd = 8000번대
#
# [SET_ME] 첫 실행 후 .env.{env} 수정 필요:
# - DOMAIN_EAI / DOMAIN_LLM
# - IMG_* (실제 이미지 태그)
# - 비밀번호/키
# ============================================================

set -Eeuo pipefail

ENV_NAME="${1:-}"
if [[ "${ENV_NAME}" != "dev" && "${ENV_NAME}" != "stg" && "${ENV_NAME}" != "prd" ]]; then
  echo "[ERROR] 환경을 지정하세요: dev | stg | prd"
  echo "  ex) sudo $0 dev"
  echo "  ex) sudo $0 dev up backend"
  exit 1
fi
shift

ACTION="${1:-up}"
shift 2>/dev/null || true
SERVICE_TARGETS=("$@")

case "${ENV_NAME}" in
  dev) PORT_BASE=6000 ;;
  stg) PORT_BASE=9000 ;;
  prd) PORT_BASE=8000 ;;
esac

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
    export DEBIAN_FRONTEND=noninteractive
    export NEEDRESTART_MODE=a
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

  local env_upper
  env_upper="$(echo "${ENV_NAME}" | tr '[:lower:]' '[:upper:]')"

  log "Creating ${envfile} (placeholders included) ..."
  cat > "${envfile}" <<EOF
ENV_NAME=${ENV_NAME}
LE_DIR=${LE_DIR_DEFAULT}
CERTBOT_WEBROOT=${CERTBOT_WEBROOT_DEFAULT}

# [SET_ME] 도메인
DOMAIN_EAI=eai.${ENV_NAME}.local
DOMAIN_LLM=llm.${ENV_NAME}.local

# ===== images (SET_ME: 실제 레지스트리/태그) =====
IMG_BACKEND=your-org/spring-boot-backend:${ENV_NAME}
IMG_STT_WORKER=your-org/stt-worker:${ENV_NAME}
IMG_LLM_WORKER=your-org/llm-worker:${ENV_NAME}
IMG_OCR_API=your-org/ocr-api:${ENV_NAME}
IMG_OCR_WORKER=your-org/ocr-worker:${ENV_NAME}
IMG_LLM_API=your-org/llm-api:${ENV_NAME}

IMG_MIC_SR=your-org/mic-speech-recognize:${ENV_NAME}
IMG_SPEECH_SR=your-org/speech-recognize:${ENV_NAME}
IMG_STT_API=your-org/stt-api:${ENV_NAME}

MIC_SR_BASE=http://mic_speech_recognize:8017
SPEECH_SR_BASE=http://speech_recognize:8016
STT_API_BASE=http://stt_api:8000
LLM_API_BASE=http://llm_api:8080
OCR_API_BASE=http://ocr_api:8080

STT_RESOURCE_DIR_REL=src/resources
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

# credentials [SET_ME]
MARIADB_ROOT_PASSWORD=ChangeMeRoot_${env_upper}
BIZ_DB_USER=bizuser
BIZ_DB_PASSWORD=ChangeMeBiz_${env_upper}
LOG_DB_USER=loguser
LOG_DB_PASSWORD=ChangeMeLog_${env_upper}

MINIO_ROOT_USER=minio
MINIO_ROOT_PASSWORD=ChangeMeMinio_${env_upper}

NEO4J_USER=neo4j
NEO4J_PASSWORD=ChangeMeNeo4j_${env_upper}
EOF

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
    proxy_pass http://127.0.0.1:$((PORT_BASE+121));
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
    proxy_pass http://127.0.0.1:$((PORT_BASE+1));
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

sentinel resolve-hostnames yes
sentinel announce-hostnames yes

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
  etcd_data: {}
  milvus_data: {}

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
      BIZ_DB_PORT: "${BIZ_DB_PORT}"
      LOG_DB_HOST: mariadb_log
      LOG_DB_PORT: "${LOG_DB_PORT}"

      RDB_USER: "${BIZ_DB_USER}"
      RDB_PASSWORD: "${BIZ_DB_PASSWORD}"
      RDB_HOST: mariadb_primary
      RDB_PORT: "3306"
      RDB_NAME: biz
      REDIS_SENTINELS: "redis_sentinel_1:26379,redis_sentinel_2:26379,redis_sentinel_3:26379"
      REDIS_MASTER_NAME: "mymaster"
      MINIO_ENDPOINT: "http://minio:9000"
    depends_on:
      - mariadb_primary
      - mariadb_log
      - redis_master
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
    depends_on: [redis_master]
    networks: [app_net, data_net]
    restart: unless-stopped

  llm_worker:
    image: ${IMG_LLM_WORKER}
    container_name: llm_worker
    environment:
      APP_PORT: "${APP_PORT}"
      REDIS_SENTINELS: "redis_sentinel_1:26379,redis_sentinel_2:26379,redis_sentinel_3:26379"
      REDIS_MASTER_NAME: "mymaster"
      LLM_API_BASE: "${LLM_API_BASE}"
    depends_on: [redis_master, llm_api]
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
    depends_on: [minio, redis_master]
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
    depends_on: [ocr_api, minio, mariadb_log, vector_db, graph_db, redis_master]
    networks: [app_net, data_net]
    restart: unless-stopped

  llm_api:
    image: ${IMG_LLM_API}
    container_name: llm_api
    environment:
      APP_PORT: "${APP_PORT}"
      VECTOR_DB_HOST: vector_db
      GRAPH_DB_HOST: graph_db
      ELASTICSEARCH_HOST: elasticsearch

      TENANT_ID: "${TENANT_ID}"
      DOC_NAMESPACE_PREFIX: "${DOC_NAMESPACE_PREFIX}"
      SEARCH_INDEX_PREFIX: "${SEARCH_INDEX_PREFIX}"

      REDIS_SENTINELS: "redis_sentinel_1:26379,redis_sentinel_2:26379,redis_sentinel_3:26379"
      REDIS_MASTER_NAME: "mymaster"
    depends_on: [vector_db, graph_db, elasticsearch, redis_master]
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
    volumes: [ "./redis/sentinel/sentinel-1.conf:/etc/redis/sentinel.conf" ]
    depends_on: [redis_master, redis_replica_1, redis_replica_2]
    networks: [data_net]
    restart: unless-stopped

  redis_sentinel_2:
    image: redis:7-alpine
    container_name: redis_sentinel_2
    command: ["redis-sentinel","/etc/redis/sentinel.conf"]
    volumes: [ "./redis/sentinel/sentinel-2.conf:/etc/redis/sentinel.conf" ]
    depends_on: [redis_master, redis_replica_1, redis_replica_2]
    networks: [data_net]
    restart: unless-stopped

  redis_sentinel_3:
    image: redis:7-alpine
    container_name: redis_sentinel_3
    command: ["redis-sentinel","/etc/redis/sentinel.conf"]
    volumes: [ "./redis/sentinel/sentinel-3.conf:/etc/redis/sentinel.conf" ]
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

  # Milvus (Vector DB - GPU)
  etcd:
    image: quay.io/coreos/etcd:v3.5.18
    container_name: milvus_etcd
    environment:
      - ETCD_AUTO_COMPACTION_MODE=revision
      - ETCD_AUTO_COMPACTION_RETENTION=1000
      - ETCD_QUOTA_BACKEND_BYTES=4294967296
      - ETCD_SNAPSHOT_COUNT=50000
    command: etcd -advertise-client-urls=http://127.0.0.1:2379 -listen-client-urls http://0.0.0.0:2379 --data-dir /etcd
    volumes: [ etcd_data:/etcd ]
    networks: [data_net]
    healthcheck:
      test: ["CMD", "etcdctl", "endpoint", "health"]
      interval: 30s
      timeout: 20s
      retries: 3
    restart: unless-stopped

  milvus:
    image: milvusdb/milvus:v2.6.11-gpu
    container_name: milvus
    command: ["milvus", "run", "standalone"]
    environment:
      ETCD_ENDPOINTS: etcd:2379
      MINIO_ADDRESS: minio:9000
      MINIO_ACCESS_KEY: ${MINIO_ROOT_USER}
      MINIO_SECRET_KEY: ${MINIO_ROOT_PASSWORD}
    volumes: [ milvus_data:/var/lib/milvus ]
    depends_on:
      etcd:
        condition: service_healthy
      minio:
        condition: service_started
    networks: [app_net, data_net]
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:9091/healthz"]
      interval: 30s
      start_period: 90s
      timeout: 20s
      retries: 3
    restart: unless-stopped
EOF
    # container_name에 환경 접미사 추가 (dev/stg/prd 충돌 방지)
    sed -i "s/container_name: \(.*\)/container_name: \1_${ENV_NAME}/" "${compose}"
  fi

  local compose_env="${BASE_DIR}/docker-compose.${ENV_NAME}.yml"
  if [[ ! -f "${compose_env}" ]]; then
    local P=${PORT_BASE}
    cat > "${compose_env}" <<EOF
version: "3.9"
services:
  # ── ${ENV_NAME^^} 포트 매핑 (${P}번대) ──────────────────

  # AI Services
  llm_api:
    ports: ["$((P+1)):8080"]
  stt_api:
    ports: ["$((P+2)):8000"]
  speech_recognize:
    ports: ["$((P+3)):8016"]
  mic_speech_recognize:
    ports: ["$((P+4)):8017"]
  ocr_api:
    ports: ["$((P+5)):8080"]

  # Data Stores
  vector_db:
    ports: ["$((P+6)):6333"]
  graph_db:
    ports: ["$((P+7)):7687"]
  elasticsearch:
    ports: ["$((P+8)):9200"]
  milvus:
    ports: ["$((P+16)):19530", "$((P+17)):9091"]

  # Infra - MinIO
  minio:
    ports: ["$((P+112)):9000"]

  # Infra - Backend (Spring Boot)
  backend:
    ports: ["$((P+121)):8080"]

  # Infra - MariaDB
  mariadb_log:
    ports: ["$((P+131)):3306"]
  mariadb_primary:
    ports: ["$((P+132)):3306"]
  mariadb_replica:
    ports: ["$((P+134)):3306"]

  # Infra - Redis
  redis_master:
    ports: ["$((P+135)):6379"]
  redis_replica_1:
    ports: ["$((P+136)):6379"]
  redis_replica_2:
    ports: ["$((P+137)):6379"]
  redis_sentinel_1:
    ports: ["$((P+138)):26379"]
  redis_sentinel_2:
    ports: ["$((P+139)):26379"]
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

    local P=${PORT_BASE}
    for offset in 1 2 3 4 5 6 7 8 16 17 112 121 131 132 134 135 136 137 138 139; do
      ufw allow "$((P+offset))/tcp" || true
    done
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

    local P=${PORT_BASE}
    for offset in 1 2 3 4 5 6 7 8 16 17 112 121 131 132 134 135 136 137 138 139; do
      firewall-cmd --permanent --add-port="$((P+offset))/tcp" || true
    done

    firewall-cmd --reload || true
    firewall-cmd --list-all || true
    return 0
  fi

  warn "No ufw/firewalld detected. Firewall not applied."
}

check_models() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local src_dir="${SRC_DIR:-${script_dir}}"

  log "모델 파일 존재 확인 (SRC_DIR=${src_dir}) ..."

  local all_projects=("embedding" "LLM" "ocr" "speech_recognize" "stt")
  local missing=()

  for proj in "${all_projects[@]}"; do
    if [[ ! -f "${src_dir}/.model_ok_${proj}" ]]; then
      missing+=("${proj}")
    fi
  done

  if [[ ${#missing[@]} -eq 0 ]]; then
    log "모든 모델 확인 완료"
    return 0
  fi

  warn "============================================================"
  warn "  다음 모델이 아직 다운로드되지 않았습니다:"
  warn "============================================================"
  for m in "${missing[@]}"; do
    warn "  ✗ ${m}"
  done
  warn ""
  warn "먼저 모델을 다운로드하세요:"
  warn "  cd ${src_dir} && HF_TOKEN=hf_xxxx ./model_download.sh"
  warn ""
  warn "특정 프로젝트만 다운로드:"
  warn "  ./model_download.sh embedding LLM stt ..."
  warn "============================================================"

  read -r -p "[WARN] 모델 없이 계속 진행하시겠습니까? (y/N): " answer
  if [[ "${answer}" != "y" && "${answer}" != "Y" ]]; then
    die "중단됨. model_download.sh를 먼저 실행하세요."
  fi
}

compose_cmd() {
  pushd "${BASE_DIR}" >/dev/null
  docker compose \
    --env-file ".env.${ENV_NAME}" \
    -f docker-compose.yml \
    -f "docker-compose.${ENV_NAME}.yml" \
    "$@"
  popd >/dev/null
}

list_services() {
  local P=${PORT_BASE}
  local E="${ENV_NAME}"
  log "사용 가능한 서비스 목록 (${E} / ${P}번대)"
  echo ""
  printf "  %-24s %-20s %-12s %s\n" "서비스(compose)" "설명" "포트" "컨테이너 이름"
  echo "  ── AI ─────────────────────────────────────────────────────────────"
  printf "  %-24s %-20s %-12s %s\n" "llm_api"              "LLM API"           "$((P+1))"    "llm_api_${E}"
  printf "  %-24s %-20s %-12s %s\n" "llm_worker"           "LLM Worker"        "(내부)"       "llm_worker_${E}"
  printf "  %-24s %-20s %-12s %s\n" "stt_api"              "STT API"           "$((P+2))"    "stt_api_${E}"
  printf "  %-24s %-20s %-12s %s\n" "stt_worker"           "STT Worker"        "(내부)"       "stt_worker_${E}"
  printf "  %-24s %-20s %-12s %s\n" "speech_recognize"     "화자인식"           "$((P+3))"    "speech_recognize_${E}"
  printf "  %-24s %-20s %-12s %s\n" "mic_speech_recognize" "화자인식(마이크)"    "$((P+4))"    "mic_speech_recognize_${E}"
  printf "  %-24s %-20s %-12s %s\n" "ocr_api"              "OCR API"           "$((P+5))"    "ocr_api_${E}"
  printf "  %-24s %-20s %-12s %s\n" "ocr_worker"           "OCR Worker"        "(내부)"       "ocr_worker_${E}"
  echo ""
  echo "  ── Backend ────────────────────────────────────────────────────────"
  printf "  %-24s %-20s %-12s %s\n" "backend"              "Spring Boot"       "$((P+121))"  "backend_${E}"
  printf "  %-24s %-20s %-12s %s\n" "ingress_eai"          "Nginx (EAI)"       "(host)"       "ingress_eai_${E}"
  printf "  %-24s %-20s %-12s %s\n" "ingress_llm"          "Nginx (LLM)"       "(host)"       "ingress_llm_${E}"
  echo ""
  echo "  ── Data ───────────────────────────────────────────────────────────"
  printf "  %-24s %-20s %-12s %s\n" "vector_db"            "Qdrant"            "$((P+6))"    "vector_db_${E}"
  printf "  %-24s %-20s %-12s %s\n" "graph_db"             "Neo4j (bolt)"      "$((P+7))"    "graph_db_${E}"
  printf "  %-24s %-20s %-12s %s\n" "elasticsearch"        "Elasticsearch"     "$((P+8))"    "elasticsearch_${E}"
  printf "  %-24s %-20s %-12s %s\n" "milvus"               "Milvus (GPU)"      "$((P+16))"   "milvus_${E}"
  printf "  %-24s %-20s %-12s %s\n" "etcd"                 "Milvus Etcd"       "(내부)"       "milvus_etcd_${E}"
  echo ""
  echo "  ── Infra ──────────────────────────────────────────────────────────"
  printf "  %-24s %-20s %-12s %s\n" "mariadb_primary"      "MariaDB (원본)"     "$((P+132))"  "mariadb_primary_${E}"
  printf "  %-24s %-20s %-12s %s\n" "mariadb_replica"      "MariaDB (복제)"     "$((P+134))"  "mariadb_replica_${E}"
  printf "  %-24s %-20s %-12s %s\n" "mariadb_log"          "MariaDB (로그)"     "$((P+131))"  "mariadb_log_${E}"
  printf "  %-24s %-20s %-12s %s\n" "redis_master"         "Redis (원본)"       "$((P+135))"  "redis_master_${E}"
  printf "  %-24s %-20s %-12s %s\n" "redis_replica_1"      "Redis (복제1)"      "$((P+136))"  "redis_replica_1_${E}"
  printf "  %-24s %-20s %-12s %s\n" "redis_replica_2"      "Redis (복제2)"      "$((P+137))"  "redis_replica_2_${E}"
  printf "  %-24s %-20s %-12s %s\n" "redis_sentinel_1"     "Redis Sentinel 1"  "$((P+138))"  "redis_sentinel_1_${E}"
  printf "  %-24s %-20s %-12s %s\n" "redis_sentinel_2"     "Redis Sentinel 2"  "$((P+139))"  "redis_sentinel_2_${E}"
  printf "  %-24s %-20s %-12s %s\n" "redis_sentinel_3"     "Redis Sentinel 3"  "(내부)"       "redis_sentinel_3_${E}"
  printf "  %-24s %-20s %-12s %s\n" "minio"                "MinIO"             "$((P+112))"  "minio_${E}"
  echo ""
  echo "  사용 예시:"
  echo "    sudo $0 ${ENV_NAME} up backend              # backend만 기동"
  echo "    sudo $0 ${ENV_NAME} up stt_api milvus       # 여러 개 기동"
  echo "    sudo $0 ${ENV_NAME} restart backend         # 재시작"
  echo "    sudo $0 ${ENV_NAME} logs stt_api            # 로그"
  echo ""
}

compose_up() {
  local envfile="${BASE_DIR}/.env.${ENV_NAME}"
  [[ -f "${envfile}" ]] || die "Missing ${envfile}"

  if [[ ${#SERVICE_TARGETS[@]} -gt 0 ]]; then
    log "선택 서비스 기동: ${SERVICE_TARGETS[*]}"
    compose_cmd up -d "${SERVICE_TARGETS[@]}"
  else
    log "전체 서비스 기동 (${ENV_NAME})"
    compose_cmd up -d
  fi
  echo ""
  compose_cmd ps
}

compose_action() {
  local envfile="${BASE_DIR}/.env.${ENV_NAME}"
  [[ -f "${envfile}" ]] || die "Missing ${envfile}"

  case "${ACTION}" in
    up)
      compose_up
      ;;
    down)
      log "전체 서비스 중지 (${ENV_NAME})"
      compose_cmd down
      ;;
    ps)
      compose_cmd ps
      ;;
    logs)
      if [[ ${#SERVICE_TARGETS[@]} -gt 0 ]]; then
        compose_cmd logs -f --tail=100 "${SERVICE_TARGETS[@]}"
      else
        compose_cmd logs -f --tail=50
      fi
      ;;
    restart)
      if [[ ${#SERVICE_TARGETS[@]} -eq 0 ]]; then
        die "restart할 서비스를 지정하세요. ex) $0 ${ENV_NAME} restart backend"
      fi
      log "서비스 재시작: ${SERVICE_TARGETS[*]}"
      compose_cmd restart "${SERVICE_TARGETS[@]}"
      compose_cmd ps
      ;;
    list)
      list_services
      ;;
    *)
      die "알 수 없는 액션: ${ACTION}\n  지원: up | down | ps | logs | restart | list"
      ;;
  esac
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

  # down/ps/logs/restart/list는 설치 과정 없이 바로 실행
  if [[ "${ACTION}" != "up" ]]; then
    compose_action
    return
  fi

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
  check_models
  compose_action

  log "DONE (${ENV_NAME}): ${BASE_DIR}"
  warn "[SET_ME] 반드시 ${BASE_DIR}/.env.${ENV_NAME} 수정 후 재기동 필요할 수 있음"
}

main