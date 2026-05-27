#!/usr/bin/env bash
# ============================================================
# jenkins.sh - Jenkins 컨테이너 관리
#
# Usage:
#   sudo ./jenkins.sh up          # Jenkins 시작
#   sudo ./jenkins.sh down        # Jenkins 중지
#   sudo ./jenkins.sh ps          # 상태 확인
#   sudo ./jenkins.sh logs        # 로그 보기
#   sudo ./jenkins.sh password    # 초기 비밀번호 확인
# ============================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.jenkins.yml"

log()  { echo -e "\033[1;32m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*" >&2; }
die()  { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; exit 1; }

jenkins_compose() {
  docker compose -f "${COMPOSE_FILE}" "$@"
}

case "${1:-}" in
  up)
    log "Jenkins 시작..."
    jenkins_compose up -d
    echo ""
    jenkins_compose ps
    echo ""
    log "Jenkins UI: http://<서버IP>:8888"
    log "초기 비밀번호 확인: sudo $0 password"
    ;;
  down)
    log "Jenkins 중지..."
    jenkins_compose down
    ;;
  ps)
    jenkins_compose ps
    ;;
  logs)
    jenkins_compose logs -f --tail=100
    ;;
  password)
    log "Jenkins 초기 관리자 비밀번호:"
    docker exec jenkins cat /var/jenkins_home/secrets/initialAdminPassword 2>/dev/null \
      || warn "아직 Jenkins가 초기화 중이거나 비밀번호가 이미 변경되었습니다."
    ;;
  *)
    echo "Usage: sudo $0 {up|down|ps|logs|password}"
    exit 1
    ;;
esac
