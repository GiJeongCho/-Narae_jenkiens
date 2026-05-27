#!/usr/bin/env bash
# ============================================================
# git_clone.sh - 프로젝트 리포지토리 자동 clone / pull
#
# Usage:
#   ./git_clone.sh                    # 기본 branch(main)로 clone/pull
#   BRANCH=develop ./git_clone.sh     # 특정 branch
#   WORKSPACE=/dev/workspace ./git_clone.sh  # 다른 경로에 clone
# ============================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="${WORKSPACE:-${SCRIPT_DIR}}"
BRANCH="${BRANCH:-main}"

GIT_BASE="ssh://git@git.biz.ppsystem.co.kr:10022/narea"

declare -A REPOS=(
  ["speech_recognize"]="${GIT_BASE}/speech_recognize.git"
  ["stt"]="${GIT_BASE}/stt.git"
  ["ocr"]="${GIT_BASE}/ocr.git"
  ["LLM"]="${GIT_BASE}/llm.git"
  ["embedding"]="${GIT_BASE}/embedding.git"
)

REPO_ORDER=("embedding" "LLM" "stt" "speech_recognize" "ocr")

log()  { echo -e "\033[1;32m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*" >&2; }
err()  { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; exit 1; }

clone_or_pull() {
  local dir="$1" url="$2"
  local target="${WORKSPACE}/${dir}"

  if [[ -d "${target}/.git" ]]; then
    log "${dir}: 이미 존재 -> fetch & pull (branch: ${BRANCH})"
    pushd "${target}" >/dev/null

    git fetch --all --prune

    local current_branch
    current_branch="$(git branch --show-current)"

    if [[ "${current_branch}" != "${BRANCH}" ]]; then
      if git show-ref --verify --quiet "refs/remotes/origin/${BRANCH}"; then
        git checkout "${BRANCH}" 2>/dev/null || git checkout -b "${BRANCH}" "origin/${BRANCH}"
      else
        warn "${dir}: 원격에 '${BRANCH}' branch 없음 -> 현재 branch(${current_branch}) 유지"
      fi
    fi

    current_branch="$(git branch --show-current)"
    git pull origin "${current_branch}" || warn "${dir}: pull 실패"

    popd >/dev/null
  else
    log "${dir}: clone 시작 -> ${url} (branch: ${BRANCH})"
    if git clone --branch "${BRANCH}" "${url}" "${target}" 2>/dev/null; then
      log "${dir}: clone 완료 (branch: ${BRANCH})"
    else
      warn "${dir}: '${BRANCH}' branch 없음 -> 기본 branch로 clone"
      git clone "${url}" "${target}" || err "${dir}: clone 실패"
    fi
  fi
}

main() {
  log "=========================================="
  log "  Git Clone / Pull"
  log "=========================================="
  log "Workspace : ${WORKSPACE}"
  log "Branch    : ${BRANCH}"
  echo ""

  local failed=0

  for dir in "${REPO_ORDER[@]}"; do
    local url="${REPOS[${dir}]}"
    if clone_or_pull "${dir}" "${url}"; then
      log "${dir}: OK"
    else
      warn "${dir}: 문제 발생"
      ((failed++)) || true
    fi
    echo ""
  done

  echo "=========================================="
  if [[ ${failed} -eq 0 ]]; then
    log "모든 리포지토리 준비 완료 (${#REPO_ORDER[@]}/${#REPO_ORDER[@]})"
  else
    warn "실패: ${failed}개 / 전체: ${#REPO_ORDER[@]}개"
  fi
  echo "=========================================="
}

main "$@"
