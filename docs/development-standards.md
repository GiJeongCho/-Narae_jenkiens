# Jenkins / 배포 - 개발 표준 (AI 추론 스택 통합)

문서 버전: 1.0
대상 독자: 백엔드/AI 개발자, DevOps, 인프라
관련 문서: [`./development-environment.md`](./development-environment.md)

---

## 목차

1. 개요
2. 개발환경
   2.1 개발환경 구성도 (전체 스택)
   2.2 개발절차 (서비스 라이프사이클)
   2.3 개발자/운영자 PC 구성 내역
   2.4 IDE / 운영 도구
   2.5 소스 관리 (사내 Git + GitHub 미러)
   2.6 Nexus / 모델 저장소 / 컨테이너 레지스트리
   2.7 IDE 설정 및 런타임 설치
       2.7.1 IDE 설정 (Cursor / VSCode)
       2.7.2 Docker / Compose 설치
       2.7.3 NVIDIA Container Toolkit
       2.7.4 Jenkins 호스트 초기화
       2.7.5 SSH 키 / Credentials 등록
       2.7.6 사내 Nginx / 인증서
3. 환경 분리 표준 (dev / stg / prd)
4. 스크립트 작성 표준 (Bash)
5. Compose / 컨테이너 표준
6. Jenkins Job 표준
7. Git 정책
8. 모델 / 데이터 관리
9. AI 서비스 공통 코드 표준
10. 보안 표준
11. 로그 / 관측 표준
12. 변경 관리 / PR
13. 백업 / 복구 표준
14. 개발자 체크리스트 (서비스 변경 시)

---

## 1. 개요

본 문서는 AI 추론 스택 5종(**OCR / LLM / STT / Speaker Recognition / Embedding**) 의 **CI/CD, 배포 스크립트, 환경 분리, 운영 규칙**에 대한 표준입니다.
신규 서비스 추가, 환경 추가, 자동화 Job 생성 시 본 문서를 우선 참조합니다.

| 구분 | 도구 / 기술 |
|------|-------------|
| CI/CD | Jenkins LTS (JDK 21) |
| 컨테이너 | Docker Engine + docker compose plugin |
| 가속기 | NVIDIA GPU + Container Toolkit |
| 소스 관리 | 사내 Gitea + GitHub 미러 (이중 푸시) |
| 모델 저장소 | Hugging Face Hub / ModelScope / 사내 NAS |
| Registry | 사내 Docker Registry |
| 시크릿 | Jenkins Credentials Store |
| Reverse Proxy | Nginx + Let's Encrypt |

---

## 2. 개발환경

### 2.1 개발환경 구성도 (전체 스택)

```
                              ┌────────────────────────────────────┐
                              │            Developer PC             │
                              │  Cursor IDE  /  VSCode  /  PyCharm  │
                              │   + Python 3.10/3.11 + uv + Docker  │
                              └────────────────┬───────────────────┘
                                               │ git push (origin)
              ┌────────────────────────────────┼────────────────────────────────┐
              ▼                                ▼                                ▼
   ┌──────────────────────┐         ┌──────────────────────┐         ┌──────────────────────┐
   │  사내 Git (Gitea)     │         │  GitHub 미러 (push)   │         │  사내 Nexus           │
   │  git.biz.pps...      │         │  GiJeongCho/*         │         │  PyPI / Docker proxy │
   └──────────┬───────────┘         └──────────────────────┘         └──────────────────────┘
              │ clone/pull (Jenkins)
              ▼
   ┌─────────────────────────────────────────────────────────────────────────────────┐
   │                          Jenkins Server (host)                                   │
   │   jenkins/jenkins:lts-jdk21  (port 8888)                                         │
   │   /var/run/docker.sock 마운트 → 호스트 docker 직접 제어                              │
   │                                                                                   │
   │   ┌─ 00-clone-repos ──────────────────────────────────────────────────────────┐ │
   │   │   dev/git_clone.sh  → 5개 service repo clone/pull                           │ │
   │   └────────────────────────────────────────────────────────────────────────────┘ │
   │   ┌─ 10-download-models ─────────────────────────────────────────────────────┐ │
   │   │   HF_TOKEN, dev/model_download.sh → 모델 사전 배치                         │ │
   │   └────────────────────────────────────────────────────────────────────────────┘ │
   │   ┌─ 20-deploy-<env> ────────────────────────────────────────────────────────┐ │
   │   │   sudo dev/docker.sh <env> up [service...]                                  │ │
   │   │     → /opt/llm-stack/deploy/.env.<env> + docker-compose.yml 자동 생성       │ │
   │   └────────────────────────────────────────────────────────────────────────────┘ │
   │   ┌─ 90-health-check ────────────────────────────────────────────────────────┐ │
   │   │   각 서비스 /health 주기 호출                                                │ │
   │   └────────────────────────────────────────────────────────────────────────────┘ │
   └────────────────────────────┬────────────────────────────────────────────────────┘
                                ▼
   ┌──────────────────────────────────────────────────────────────────────────────────┐
   │            /opt/llm-stack/deploy   (실제 비즈니스 스택)                            │
   │   ┌─ Ingress ─┐  ┌─────────────── App ───────────────┐  ┌──── Data layer ────┐ │
   │   │ nginx_eai │  │ backend (Spring Boot)             │  │ mariadb_primary    │ │
   │   │ nginx_llm │  │ ocr_api  llm_api  stt_api         │  │ mariadb_log        │ │
   │   └───────────┘  │ speech_recognize  mic_sr embedding │  │ redis (sentinel)   │ │
   │                  └────────────────────────────────────┘  │ minio milvus etcd  │ │
   │                                                          │ elasticsearch neo4j│ │
   │                                                          └────────────────────┘ │
   └──────────────────────────────────────────────────────────────────────────────────┘
```

### 2.2 개발절차 (서비스 라이프사이클)

1. 개발자가 사내 Git 에서 feature 브랜치 생성 → 로컬 개발.
2. PR → 코드리뷰 → develop(또는 main) 머지.
3. Jenkins Webhook 또는 수동 트리거로 `00-clone-repos` 실행.
4. 모델 갱신이 있으면 `10-download-models` 실행 (`HF_TOKEN` 사용).
5. `20-deploy-dev` 실행 → 이미지 빌드 + `/opt/llm-stack/deploy` 갱신 + 컨테이너 재기동.
6. `90-health-check` 자동 실행 → `/health` 모두 200 확인.
7. dev 검증 통과 → `20-deploy-stg` 승격.
8. QA 통과 → 변경관리 승인 후 `20-deploy-prd` 승격.

### 2.3 개발자/운영자 PC 구성 내역

| 항목 | 최소 | 권장 | 비고 |
|------|------|------|------|
| OS | Ubuntu 20.04 LTS | Ubuntu 22.04 LTS / macOS | Jenkins 호스트는 Linux 필수 |
| CPU | 4 core | 8+ core | |
| RAM | 16 GB | 32 GB+ | 로컬 컨테이너 동시 기동 시 |
| Disk | 100 GB | 1 TB SSD | 로그/이미지/모델 캐시 |
| Docker | 24.x | 26.x | `docker compose` plugin |
| `gh` CLI | 선택 | 권장 | GitHub PR 자동화 |
| `kubectl`, `helm` | 선택 | - | 향후 K8s 이행 시 |

### 2.4 IDE / 운영 도구

- 개발: Cursor / VSCode / PyCharm.
- 운영: 터미널(zsh/bash) + `tmux` + `lazygit` 권장.
- 모니터링 보조: `lazydocker`, `ctop`, `dive`(이미지 분석).

### 2.5 소스 관리 (사내 Git + GitHub 미러)

| 서비스 | 사내 Git | GitHub 미러 |
|--------|---------|-------------|
| `dev/ocr` | `narea/ocr.git` | `GiJeongCho/OCR` |
| `dev/stt` | `narea/stt.git` | `GiJeongCho/whisperX` |
| `dev/speech_recognize` | `narea/speech_recognize.git` | `GiJeongCho/speech_recognize` |
| `dev/LLM` | `narea/llm.git` | `GiJeongCho/gemma31b_service` |
| `dev/embedding` | `narea/embedding.git` | `GiJeongCho/embedding` |

- 각 저장소의 `origin` 은 fetch 1 + push 2 로 구성 → `git push origin <branch>` 한 번에 양쪽 반영.
- 검증: `git remote -v` 출력에서 push URL 두 줄이 보여야 함.

### 2.6 Nexus / 모델 저장소 / 컨테이너 레지스트리

| 자원 | 위치 | 사용처 |
|------|------|--------|
| Nexus (PyPI proxy) | `https://nexus.biz.ppsystem.co.kr/repository/pypi-proxy/simple/` | 오프라인/제한망 빌드 |
| Nexus (Docker proxy) | `nexus.biz.ppsystem.co.kr:5000` | Base image 캐싱 |
| 사내 Docker Registry | `<registry>` (`.env.<env>` 의 `IMG_*` prefix) | 서비스 이미지 push/pull |
| HF / ModelScope 미러 | 사내 NAS `/mnt/nas/models/` | gated 모델 / 대용량 모델 |
| Git LFS | 사용 안 함 | 모델은 코드에 포함 금지 |

### 2.7 IDE 설정 및 런타임 설치

#### 2.7.1 IDE 설정 (Cursor / VSCode)

워크스페이스 멀티 폴더 권장 (`.code-workspace`):

```json
{
  "folders": [
    { "path": "/home/pps-nipa/jenkins" },
    { "path": "/home/pps-nipa/jenkins/dev/ocr" },
    { "path": "/home/pps-nipa/jenkins/dev/LLM" },
    { "path": "/home/pps-nipa/jenkins/dev/stt" },
    { "path": "/home/pps-nipa/jenkins/dev/speech_recognize" },
    { "path": "/home/pps-nipa/jenkins/dev/embedding" }
  ],
  "settings": {
    "files.exclude": {
      "**/.venv/**": true,
      "**/__pycache__": true,
      "**/uv.lock": false
    },
    "terminal.integrated.cwd": "/home/pps-nipa/jenkins"
  }
}
```

#### 2.7.2 Docker / Compose 설치

```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
docker compose version
```

#### 2.7.3 NVIDIA Container Toolkit

```bash
distribution=$(. /etc/os-release; echo $ID$VERSION_ID)
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/${distribution}/libnvidia-container.list | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
sudo apt-get update && sudo apt-get install -y nvidia-container-toolkit
sudo systemctl restart docker
```

#### 2.7.4 Jenkins 호스트 초기화

```bash
cd /home/pps-nipa/jenkins
sudo ./jenkins.sh up
sudo ./jenkins.sh password   # initialAdminPassword
# 브라우저 → http://<서버IP>:8888 → 초기 셋업 위저드 진행
```

권장 설치 플러그인:
- **Pipeline** (suggested 묶음)
- **Git**, **SSH Build Agents**
- **Credentials Binding**
- **Pipeline: Stage View**
- **Build Timeout**, **Timestamper**
- **ANSI Color** (`docker.sh` 의 색상 출력)
- (선택) **Docker Pipeline**

#### 2.7.5 SSH 키 / Credentials 등록

호스트 측 (이미 docker-compose.jenkins.yml 가 read-only 마운트):
```
/home/pps-nipa/.ssh/id_ed25519       → /root/.ssh/id_ed25519
/home/pps-nipa/.ssh/known_hosts      → /root/.ssh/known_hosts
```

Jenkins UI 측 등록:
- `HF_TOKEN` → Secret text.
- `DOCKER_REGISTRY_CRED` → Username/Password (사내 Registry push 용).
- `GITHUB_PAT` → Secret text (선택. HTTPS Push 시).

#### 2.7.6 사내 Nginx / 인증서

- `docker.sh` 가 `/opt/llm-stack/deploy/nginx/` 에 환경별 conf 를 자동 생성.
- Let's Encrypt 사용 시:
  - `LE_DIR=/etc/letsencrypt`, `CERTBOT_WEBROOT=/var/www/certbot` 마운트.
  - cert 가 없으면 self-signed 로 자동 부팅.

---

## 3. 환경 분리 표준 (dev / stg / prd)

| 환경 | 용도 | 포트 베이스 | 디렉토리 |
|------|------|-------------|----------|
| `dev` | 개발 | **6000번대** | `/home/pps-nipa/jenkins/dev/` |
| `stg` | 스테이징 | **9000번대** | `/home/pps-nipa/jenkins/stg/` |
| `prd` | 운영 | **8000번대** | `/home/pps-nipa/jenkins/prd/` |

- Jenkins UI 자체는 환경 규칙과 분리하여 `8888` 사용.
- 비즈니스 스택은 항상 `/opt/llm-stack/deploy/` 아래에 환경별로 생성됩니다.
- 절대 `dev/`, `stg/`, `prd/` 디렉토리 안에 실데이터를 두지 않는다(코드/스크립트만).
- `.env.<env>` 는 `docker.sh` 가 처음 실행 시 생성. **수동 편집 금지(IMG_*/비밀번호 제외)**.
- 비밀번호/토큰은 **반드시 Jenkins Credentials** 로 주입.

---

## 4. 스크립트 작성 표준 (Bash)

본 디렉토리의 모든 스크립트(`docker.sh`, `git_clone.sh`, `model_download.sh`, `jenkins.sh`)는 다음 규칙을 따릅니다.

### 4.1 헤더
```bash
#!/usr/bin/env bash
# ============================================================
# <스크립트명> - 한 줄 목적
#
# Usage:
#   <예시 명령들>
# ============================================================
set -Eeuo pipefail
```

### 4.2 로깅 헬퍼
```bash
log()  { echo -e "\033[1;32m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*" >&2; }
die()  { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; exit 1; }
```

### 4.3 규칙
- 변수는 **항상 `"${VAR}"` 로 인용**.
- `cd` 대신 `pushd`/`popd` 또는 절대경로 사용.
- 외부 명령은 존재 여부 점검 (`command -v docker >/dev/null || die "..."`).
- 멱등성 보장: 이미 존재하는 자원은 건드리지 않거나 안전하게 갱신.
- `SET_ME` 주석으로 운영자가 손대야 하는 부분 명시.
- 시스템 설치가 필요한 스크립트는 `require_root` 함수로 권한 체크.

---

## 5. Compose / 컨테이너 표준

### 5.1 이미지 태그
- 형식: `<registry>/<service>:<env>` (예: `your-org/stt-api:dev`).
- `.env.<env>` 의 `IMG_*` 만 수정. 컴포즈 파일은 plain placeholder 유지.

### 5.2 서비스명
- compose 서비스명은 **언더스코어**(`stt_api`, `llm_api`, `speech_recognize`).
- 내부 DNS도 동일 이름으로 접근.

### 5.3 네트워크
- 두 개의 브리지: `app_net`, `data_net`.
  - `app_net`: 백엔드 ↔ AI 추론 ↔ ingress
  - `data_net`: DB, Redis, MinIO, ES 등 데이터 계층
- AI 컨테이너는 양 네트워크에 모두 붙는다(`networks: [app_net, data_net]`).

### 5.4 볼륨
- DB/Object Storage 는 **named volume** 사용.
- 모델 가중치는 **호스트 read-only 마운트**.
- `dev` 환경에서만 코드 핫리로드를 위한 bind mount 허용.

### 5.5 포트 노출 정책
- prd 환경의 AI 컨테이너는 **호스트 포트 노출 금지** (Nginx ingress 통해서만 접근).
- dev/stg 는 디버깅 위해 호스트 포트 오픈 가능.

### 5.6 healthcheck
모든 서비스는 `/health` 노출. compose 에 `healthcheck:` 정의:
```yaml
healthcheck:
  test: ["CMD", "curl", "-fsS", "http://localhost:${APP_PORT}/health"]
  interval: 30s
  timeout: 5s
  retries: 5
```

### 5.7 자원 제한
- GPU 컨테이너:
  ```yaml
  deploy:
    resources:
      reservations:
        devices:
          - driver: nvidia
            count: 1
            capabilities: [gpu]
  ```
- 데이터 계층 컨테이너는 메모리/CPU 제한을 환경별로 명시 (`mem_limit`, `cpus`).

---

## 6. Jenkins Job 표준

### 6.1 명명
- 환경 prefix + 단계 번호 + 명칭: `dev-20-deploy-stt`, `prd-10-download-models`.
- Multibranch 사용 시 `<env>/<service>` 폴더 구조.

### 6.2 파이프라인
- 가급적 **`Jenkinsfile` 을 각 서비스 repo 루트**에 두고 코드와 함께 버저닝.
- 공통 단계:
  1. `Checkout`
  2. `Lint / Test`
  3. `Build Image` (`docker build -t <registry>/<svc>:<env>-<sha> .`)
  4. `Push`
  5. `Deploy` (`/home/pps-nipa/jenkins/<env>/docker.sh <env> up <svc>`)
  6. `Health Check` (재시도 5회)

### 6.3 자격증명 사용
- `HF_TOKEN`, Git SSH key, Registry creds 는 **Jenkins Credentials Store** 만 사용.
- `withCredentials` 블록 안에서만 노출. echo / 로그 금지.

### 6.4 동시성
- 동일 환경 동일 서비스에 대해 `lock` 사용 (`lock(resource: 'deploy-dev-stt')`).
- 다른 서비스는 병렬 허용.

### 6.5 알림
- 빌드 실패 / 헬스체크 실패 시 메신저/이메일 알림 표준화(향후 슬랙 채널 합의 후 보강).

---

## 7. Git 정책

### 7.1 저장소 (재정리)
| repo | 디렉토리 |
|------|---------|
| `narea/embedding.git` | `dev/embedding` |
| `narea/llm.git` | `dev/LLM` |
| `narea/stt.git` | `dev/stt` |
| `narea/speech_recognize.git` | `dev/speech_recognize` |
| `narea/ocr.git` | `dev/ocr` |

### 7.2 브랜치 전략
- `main` — prd 배포 대상.
- `stg` (또는 `release/*`) — stg 배포 대상.
- `develop` — dev 배포 대상.
- 기능 브랜치 → PR → develop.

### 7.3 자동화 동기화
- `git_clone.sh` 는 **삭제하지 않고 fetch + checkout + pull**. 로컬 변경분이 있으면 PR로 정리(자동 stash 금지).

### 7.4 이중 푸시 정책 (사내 + GitHub)
- 모든 5개 서비스는 origin 에 push URL 두 개를 가지도록 표준화 완료.
- 검증 명령:
  ```bash
  for d in ocr LLM stt speech_recognize embedding; do
    echo "=== $d ==="
    git -C /home/pps-nipa/jenkins/dev/$d remote -v
  done
  ```

---

## 8. 모델 / 데이터 관리

### 8.1 모델 자동 다운로드
- 각 서비스 repo 루트에 `scripts/download_models.py`(또는 동등 스크립트)를 둔다.
- 표준 인자:
  - `--output <dir>` — 모델 저장 위치
- `model_download.sh` 가 자동 호출.
- 다운로드 완료 시 `dev/.model_ok_<service>` 마커 파일 생성 → 다른 Job 이 의존 가능.

### 8.2 모델 저장 경로 표준
- 컨테이너 내부: `/app/src/resources/models/...` 또는 서비스별 규약.
- 호스트: `dev/<service>/src/resources/models/...` → 컨테이너에 read-only 마운트.
- LLM 모델은 별도 디스크 사용: `LLM_MODEL_DIR=/data/models/<name>` 권장.

### 8.3 모델 보안
- gated 모델(`google/gemma-*`, `pyannote/speaker-*`)은 사내 미러 등록 검토.
- `HF_TOKEN` 은 항상 Jenkins Credentials 로만 노출.

---

## 9. AI 서비스 공통 코드 표준

각 서비스의 상세 표준은 해당 `docs/development-standards.md` 를 따릅니다. 공통 규칙:

- **FastAPI 기반**. 엔드포인트는 RESTful + 명사형 리소스 + 동사 행위.
- 모델 로딩은 **FastAPI lifespan** 에서 1회만.
- 모든 서비스는 `GET /health` 노출.
- 장시간 추론은 **Job + BackgroundTasks 패턴** (LLM 의 SSE 는 예외).
- 응답 시간/타임스탬프는 **KST(UTC+9) ISO 8601** 통일.
- 임시 업로드 파일은 `finally` 절에서 반드시 삭제.
- 포트 규칙(dev 6000번대 / stg 9000번대 / prd 8000번대) 준수.

---

## 10. 보안 표준

### 10.1 시크릿 관리
- 코드/이미지에 시크릿 포함 절대 금지.
- 우선순위: **Jenkins Credentials > 환경변수 > .env.<env>** (`.env.<env>` 는 외부 접근 권한 차단).

### 10.2 Docker socket
- Jenkins 컨테이너가 host docker socket 을 마운트하므로 **Jenkins 자체 접근 제어가 곧 호스트 권한**이다.
  - UI는 사내망/VPN으로만 노출.
  - 사용자 권한은 RBAC 으로 분리(읽기 전용 사용자/관리자 분리).

### 10.3 TLS
- 외부 도메인은 Let's Encrypt 사용 표준화. self-signed 는 부팅 폴백 용도.

### 10.4 방화벽
- `docker.sh` 의 `APPLY_FIREWALL` 옵션을 사용해 환경별 포트만 ufw/firewalld 로 허용.
- SSH 포트는 `ALLOW_SSH_PORT` 로 명시(기본 22).

### 10.5 OS 패치
- Base image 의 보안 패치는 분기에 1회 이상 재빌드 권장.
- 의존성 CVE 모니터링: `pip-audit`, `trivy image` 정기 실행.

---

## 11. 로그 / 관측 표준

- 컨테이너 로그는 docker driver `json-file` 또는 `journald`. 운영에선 외부 수집(파이프라인 별도 합의).
- 모든 서비스 로그 포맷:
  ```
  %(asctime)s - %(name)s - %(levelname)s - %(message)s
  ```
- 요청 단위 로그에는 `request_id` 또는 `job_id` 를 반드시 포함.
- `/health` 는 항상 200을 반환하되 payload 로 상세 상태 표시.
- 향후 도입 권장(TODO): Prometheus exporter, Grafana 대시보드, Loki/ELK 로그 수집.

---

## 12. 변경 관리 / PR

### 12.1 Jenkins/배포 스크립트 변경
- 브랜치: `infra/<topic>`.
- 커밋: `[infra] <동사> <내용>` (예: `[infra] add stg compose service for embedding`).
- PR 본문에 **실행 결과 로그 (성공/실패 양쪽)** 첨부.

### 12.2 서비스 추가 절차
1. `dev/<service>/` repo 추가 + `download_models.py`(필요 시).
2. `dev/git_clone.sh` 의 `REPOS` 와 `REPO_ORDER` 에 등록.
3. `dev/model_download.sh` 의 `ALL_PROJECTS` 및 `ensure_pip_deps` 케이스 추가.
4. `dev/docker.sh` 의 `.env.<env>` placeholder + compose 서비스 정의 + 포트 규칙 적용.
5. 본 서비스 docs(`docs/development-environment.md`, `docs/development-standards.md`) 작성.
6. Jenkins Job `dev-20-deploy-<service>` 생성.
7. (선택) GitHub 미러 push URL 등록 (사내 Git + GitHub 이중 push 패턴).

### 12.3 환경별 동기화
- dev 에서 검증된 변경만 stg/prd 로 승격.
- `docker.sh` 는 환경별 디렉토리(`dev/`, `stg/`, `prd/`)에 각각 사본을 둔다. 변경 시 **세 곳을 동기화하는 PR** 작성.

---

## 13. 백업 / 복구 표준

| 자원 | 주기 | 위치 |
|------|------|------|
| `jenkins_home` volume | 매일 | 별도 백업 스토리지 |
| MariaDB | 매일 (dump) | `/backup/mariadb/...` |
| MinIO | 정책에 따라 | 별도 객체 스토리지 |
| 모델 가중치 | 모델 갱신 시 1회 | 사내 NAS / 미러 |
| `.env.<env>` | 변경 시 (수동) | 안전한 키 보관함 |

복구 절차:
```bash
# Jenkins 복구
sudo ./jenkins.sh down
docker run --rm -v jenkins_home:/data -v /backup/jenkins:/restore \
  busybox tar xzf /restore/jenkins_home_YYYY-MM-DD.tgz -C /
sudo ./jenkins.sh up
```

---

## 14. 개발자 체크리스트 (서비스 변경 시)

- [ ] 코드 변경 PR (서비스 레포지토리)
- [ ] 해당 서비스 `docs/development-standards.md` 영향 검토
- [ ] Dockerfile / requirements.txt(혹은 pyproject) 동기
- [ ] `Jenkinsfile` (있다면) 갱신
- [ ] dev 환경 배포 후 `/health` + 기능 스모크 테스트
- [ ] stg 승격 PR (compose/.env 변경 동기화)
- [ ] prd 승격 (수동 승인 + 모니터링 윈도우)

---

## 15. 관련 문서
- 개발 환경 → [`./development-environment.md`](./development-environment.md)
- 각 서비스 docs (환경/표준)
  - [`../dev/ocr/docs/`](../dev/ocr/docs/)
  - [`../dev/LLM/docs/`](../dev/LLM/docs/)
  - [`../dev/stt/docs/`](../dev/stt/docs/)
  - [`../dev/speech_recognize/docs/`](../dev/speech_recognize/docs/)
