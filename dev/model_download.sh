#!/usr/bin/env bash
# ============================================================
# model_download.sh - 전체 프로젝트 모델 일괄 다운로드
#
# 각 프로젝트의 model_download.py를 순차 실행합니다.
# HF_TOKEN이 필요한 모델(STT pyannote 등)은 환경변수로 전달하세요.
#
# Usage:
#   HF_TOKEN=hf_xxxx ./model_download.sh          # 전체 다운로드
#   HF_TOKEN=hf_xxxx ./model_download.sh embedding # 특정 프로젝트만
#   HF_TOKEN=hf_xxxx ./model_download.sh stt ocr   # 여러 프로젝트 지정
#
# 지원 프로젝트: embedding, LLM, ocr, speech_recognize, stt
# ============================================================
set -Euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="${WORKSPACE:-${SCRIPT_DIR}}"

ALL_PROJECTS=("embedding" "LLM" "ocr" "speech_recognize" "stt")

log()  { echo -e "\033[1;32m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*" >&2; }
err()  { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; }
sep()  { echo "──────────────────────────────────────────"; }

check_hf_token() {
  if [[ -z "${HF_TOKEN:-}" ]]; then
    warn "HF_TOKEN 미설정 — pyannote/gemma 등 gated 모델 다운로드 실패 가능"
    warn "설정법: export HF_TOKEN=hf_xxxx"
    echo ""
  fi
}

ensure_pip_deps() {
  local project="$1"
  local req_file=""

  case "${project}" in
    embedding)
      req_file="${WORKSPACE}/embedding/pyproject.toml"
      python3 -c "import huggingface_hub" 2>/dev/null || pip3 install --quiet huggingface_hub
      ;;
    LLM)
      python3 -c "import transformers; import accelerate" 2>/dev/null || pip3 install --quiet transformers accelerate
      python3 -c "import huggingface_hub" 2>/dev/null || pip3 install --quiet huggingface_hub
      ;;
    ocr)
      python3 -c "import paddleocr" 2>/dev/null || {
        warn "paddleocr 미설치 — pip install paddleocr paddlepaddle 필요"
        return 1
      }
      ;;
    speech_recognize)
      python3 -c "import modelscope" 2>/dev/null || pip3 install --quiet modelscope
      ;;
    stt)
      python3 -c "import huggingface_hub" 2>/dev/null || pip3 install --quiet huggingface_hub
      ;;
  esac
  return 0
}

download_embedding() {
  local proj_dir="${WORKSPACE}/embedding"
  [[ -d "${proj_dir}" ]] || { err "embedding 디렉토리 없음: ${proj_dir}"; return 1; }

  local model_dir="${proj_dir}/src/resources/model/embedding_qwen3_0_6b"
  if [[ -d "${model_dir}" && -f "${model_dir}/config.json" ]]; then
    log "[embedding] Qwen3-Embedding-0.6B 이미 존재 → 건너뜀"
    return 0
  fi

  log "[embedding] Qwen3-Embedding-0.6B 다운로드"
  cd "${proj_dir}"
  python3 test/download_model.py
}

download_llm() {
  local proj_dir="${WORKSPACE}/LLM"
  [[ -d "${proj_dir}" ]] || { err "LLM 디렉토리 없음: ${proj_dir}"; return 1; }

  log "[LLM] Gemma-4-31B-it 모델 다운로드"
  cd "${proj_dir}"

  if [[ -d "test/model/models--google--gemma-4-31B-it" ]]; then
    log "[LLM] gemma-4-31B-it 이미 존재 → 건너뜀"
    return 0
  fi

  if [[ -f "test/download_gemma31b.py" ]]; then
    log "[LLM] gemma-4-31B-it 다운로드 중..."
    python3 test/download_gemma31b.py
  else
    err "[LLM] test/download_gemma31b.py 파일 없음"
    return 1
  fi
}

download_ocr() {
  local proj_dir="${WORKSPACE}/ocr"
  [[ -d "${proj_dir}" ]] || { err "ocr 디렉토리 없음: ${proj_dir}"; return 1; }

  if [[ -d "${HOME}/.paddleocr/whl" ]]; then
    log "[ocr] PaddleOCR 모델 캐시 이미 존재 (~/.paddleocr/whl) → 건너뜀"
    return 0
  fi

  log "[ocr] PaddleOCR / PPStructure 모델 다운로드"
  cd "${proj_dir}"
  python3 scripts/download_models.py
}

download_speech_recognize() {
  local proj_dir="${WORKSPACE}/speech_recognize"
  [[ -d "${proj_dir}" ]] || { err "speech_recognize 디렉토리 없음: ${proj_dir}"; return 1; }

  local model_dir="${proj_dir}/src/resoursces/models/iic"
  if [[ -d "${model_dir}" ]]; then
    log "[speech_recognize] Eres2NetV2 모델 이미 존재 → 건너뜀"
    return 0
  fi

  log "[speech_recognize] Eres2NetV2 화자인식 모델 다운로드"
  cd "${proj_dir}"
  python3 src/resoursces/test/Eres2NetV2_download.py
}

download_stt() {
  local proj_dir="${WORKSPACE}/stt"
  [[ -d "${proj_dir}" ]] || { err "stt 디렉토리 없음: ${proj_dir}"; return 1; }

  local models_dir="${proj_dir}/src/resources/models"
  local skip_main=false
  local skip_pyannote=false

  if [[ -d "${models_dir}/whisper" && -d "${models_dir}/alignment" ]]; then
    log "[stt] WhisperX + Alignment 모델 이미 존재 → 건너뜀"
    skip_main=true
  fi

  if [[ -d "${models_dir}/vad" && -d "${models_dir}/diarization" && -d "${models_dir}/embedding" ]]; then
    log "[stt] Pyannote(VAD/Diarization/Embedding) 모델 이미 존재 → 건너뜀"
    skip_pyannote=true
  fi

  cd "${proj_dir}"

  if [[ "${skip_main}" == false ]]; then
    log "[stt] WhisperX + Alignment + VAD + Diarization 모델 다운로드"
    python3 src/resources/download_models.py --output src/resources/models
  fi

  if [[ "${skip_pyannote}" == false ]]; then
    if [[ -n "${HF_TOKEN:-}" ]]; then
      log "[stt] Pyannote 모델 다운로드 (HF_TOKEN 사용)"
      python3 src/test/download_pyannote.py --output src/resources/models
    else
      warn "[stt] HF_TOKEN 미설정 -> pyannote 다운로드 건너뜀"
    fi
  fi
}

run_project() {
  local project="$1"
  sep
  log "▶ ${project} 모델 다운로드 시작"
  sep

  if ! ensure_pip_deps "${project}"; then
    err "${project}: 의존성 확인 실패 — 건너뜀"
    return 1
  fi

  case "${project}" in
    embedding)         download_embedding ;;
    LLM)               download_llm ;;
    ocr)               download_ocr ;;
    speech_recognize)  download_speech_recognize ;;
    stt)               download_stt ;;
    *)
      err "알 수 없는 프로젝트: ${project}"
      err "지원: ${ALL_PROJECTS[*]}"
      return 1
      ;;
  esac

  local rc=$?
  if [[ ${rc} -eq 0 ]]; then
    touch "${WORKSPACE}/.model_ok_${project}"
    log "✓ ${project} 완료"
  else
    err "✗ ${project} 실패 (exit=${rc})"
  fi
  echo ""
  return ${rc}
}

main() {
  log "=========================================="
  log "  Model Download"
  log "=========================================="
  log "Workspace : ${WORKSPACE}"
  echo ""

  check_hf_token

  local targets=()
  if [[ $# -gt 0 ]]; then
    targets=("$@")
  else
    targets=("${ALL_PROJECTS[@]}")
  fi

  local succeeded=0
  local failed=0

  for project in "${targets[@]}"; do
    if run_project "${project}"; then
      ((succeeded++))
    else
      ((failed++)) || true
    fi
  done

  sep
  log "결과: 성공=${succeeded} / 실패=${failed} / 전체=${#targets[@]}"
  sep

  if [[ ${failed} -gt 0 ]]; then
    exit 1
  fi
}

main "$@"
