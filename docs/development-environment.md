# Jenkins - 개발 환경 가이드 (AI/추론 스택 통합 배포)

> 백엔드 개발자 대상 문서.
> 본 Jenkins 인스턴스는 **AI 추론 스택(OCR / LLM / STT / Speaker Recognition / Embedding)** 의
> **clone → 모델 다운로드 → Docker build → docker-compose up** 파이프라인을 자동화하기 위한 CI/CD 서버입니다.

---

## 1. Jenkins 인스턴스 개요

| 항목 | 내용 |
|------|------|
| 이미지 | `jenkins/jenkins:lts-jdk21` |
| 컨테이너명 | `jenkins` |
| 포트 | **호스트 `8888` → 컨테이너 `8080`** (UI), `50000` (에이전트) |
| 사용자 | `root` (호스트 docker socket 제어 목적) |
| 데이터 볼륨 | named volume `jenkins_home` → `/var/jenkins_home` |
| 비즈니스 도커와의 관계 | **완전 분리**된 별도 compose 스택 |
| Java 옵션 | `JAVA_OPTS=-Xmx1g -Djenkins.install.runSetupWizard=true` |

### 1.1 마운트 구성 (`docker-compose.jenkins.yml`)

```
jenkins_home                              -> /var/jenkins_home   (Jenkins 데이터 영구화)
/var/run/docker.sock                      -> /var/run/docker.sock (호스트 docker 제어)
/usr/bin/docker                           -> /usr/bin/docker      (docker CLI 그대로 사용)
/usr/libexec/docker/cli-plugins           -> ... (read-only)      (compose 플러그인 등)
/home/pps-nipa/jenkins                    -> /workspace           (스크립트/배포 산출물)
/opt/llm-stack                            -> /opt/llm-stack       (실제 배포 디렉토리)
/home/pps-nipa/.ssh/id_ed25519            -> /root/.ssh/...:ro    (Git 사설 저장소 clone용)
/home/pps-nipa/.ssh/known_hosts           -> /root/.ssh/...:ro
```

> Docker 소켓을 그대로 마운트하므로 **Jenkins 컨테이너에서 호스트의 docker로 직접 빌드/실행**합니다 (DinD 미사용).

---

## 2. 디렉토리 구조

```
/home/pps-nipa/jenkins/
├── docker-compose.jenkins.yml   # Jenkins 인스턴스 compose
├── jenkins.sh                   # Jenkins 컨테이너 관리 (up/down/ps/logs/password)
├── docs/                        # ★ 본 문서 위치
├── dev/                         # 개발 환경 자동화 자원
│   ├── docker.sh                # dev 환경 비즈니스 스택 빌드/배포 (one-shot installer)
│   ├── docker_copy.sh           # docker.sh의 백업본
│   ├── git_clone.sh             # 5개 서비스 리포지토리 clone/pull
│   ├── model_download.sh        # 5개 서비스 모델 다운로드 (HF_TOKEN 사용)
│   ├── .model_ok_*              # 모델 준비 완료 마커
│   ├── LLM/                     # 각 서비스 워크트리 (Jenkins가 git_clone.sh 로 갱신)
│   ├── ocr/
│   ├── speech_recognize/
│   ├── stt/
│   └── embedding/
├── stg/
│   └── docker.sh                # staging 환경 배포 스크립트
└── prd/
    └── docker.sh                # production 환경 배포 스크립트
```

---

## 3. 포트 규칙 (전체 환경 통일)

`dev/docker.sh` 가 환경별 포트 베이스로 전체 스택을 일관되게 배치합니다.

| 환경 | 포트 베이스 | LLM API | STT API | Speaker | OCR API | 비고 |
|------|-------------|---------|---------|---------|---------|------|
| dev | **6000번대** | 6001 | 6002 | 6016 | 6031 | Jenkins UI는 별도 `8888` |
| stg | **9000번대** | 9001 | 9002 | 9016 | 9031 | |
| prd | **8000번대** | 8001 | 8002 | 8016 | 8031 | |

> Jenkins UI 자체는 환경 규칙과 분리해서 **`8888`** 을 사용합니다 (사람이 외우기 쉬운 포트).

---

## 4. 사전 요구사항 (호스트)

- Ubuntu 20.04 LTS+ / RHEL 계열도 가능 (apt/dnf 자동 감지)
- Docker Engine + `docker compose` 플러그인
- (선택) NVIDIA GPU + Container Toolkit (AI 추론 컨테이너용. Jenkins 자체에는 불필요)
- SSH 키 (`~/.ssh/id_ed25519`) — 사내 Git(`git.biz.ppsystem.co.kr:10022`) 접근용
- 외부 디렉토리:
  - `/opt/llm-stack` — 실제 비즈니스 배포 산출물(자동 생성)
  - `/home/pps-nipa/jenkins` — Jenkins 워크스페이스

---

## 5. Jenkins 설치 & 부팅

### 5.1 컨테이너 기동

```bash
cd /home/pps-nipa/jenkins
sudo ./jenkins.sh up
```

`jenkins.sh` 가 다음을 수행:
- `docker compose -f docker-compose.jenkins.yml up -d`
- 컨테이너 상태(`ps`) 출력
- UI URL 안내 (`http://<서버IP>:8888`)

### 5.2 초기 비밀번호 확인

```bash
sudo ./jenkins.sh password
# /var/jenkins_home/secrets/initialAdminPassword 출력
```

브라우저에서 `http://<서버IP>:8888` 접속 → 초기 셋업 위저드 진행.

### 5.3 컨테이너 운영 명령

| 명령 | 설명 |
|------|------|
| `sudo ./jenkins.sh up` | 시작 |
| `sudo ./jenkins.sh down` | 중지 |
| `sudo ./jenkins.sh ps` | 상태 확인 |
| `sudo ./jenkins.sh logs` | 실시간 로그(tail 100) |
| `sudo ./jenkins.sh password` | 초기 관리자 비밀번호 |

---

## 6. 권장 설치 플러그인 (Setup Wizard 이후)

- **Pipeline** (suggested 묶음에 포함)
- **Git** / **SSH Build Agents**
- **Credentials Binding** (HF_TOKEN, Git SSH 키)
- **Pipeline: Stage View** (시각화)
- **Docker Pipeline** (선택 — 호스트 docker 직접 사용 시 굳이 필요 없음)
- **Build Timeout**, **Timestamper**
- **ANSI Color** (`docker.sh` 의 ANSI 출력 시인성)

---

## 7. 사내 Git / Credentials 설정

### 7.1 Git URL
- 베이스: `ssh://git@git.biz.ppsystem.co.kr:10022/narea`
- 저장소:
  - `embedding.git`, `llm.git`, `stt.git`, `speech_recognize.git`, `ocr.git`

### 7.2 SSH 키 마운트
- 호스트의 `~/.ssh/id_ed25519` 가 Jenkins 컨테이너의 `/root/.ssh/id_ed25519:ro` 에 read-only로 노출되어 `git_clone.sh` 가 그대로 사용합니다.
- 키 비밀번호는 사용하지 않는 키 권장(자동화).

### 7.3 Jenkins Credentials 등록 (선택)
- `HF_TOKEN` → Secret text (`hf_xxxx`). pyannote/Gemma 등 gated 모델 다운로드용.
- 컨테이너 레지스트리 push 가 필요한 경우 username/password 등록.

---

## 8. 5개 서비스 워크플로우

### 8.1 전체 파이프라인 단계

1. **Clone / Pull** — `dev/git_clone.sh`
   - 5개 리포지토리(embedding / LLM / stt / speech_recognize / ocr) 자동 clone 또는 pull
   - 옵션: `BRANCH=develop ./git_clone.sh`
2. **모델 다운로드** — `dev/model_download.sh`
   - 각 서비스의 `download_models.py` 호출
   - `HF_TOKEN=hf_xxxx ./model_download.sh` (전체) 또는 `./model_download.sh stt ocr`
   - 완료되면 `.model_ok_<service>` 마커 파일 생성
3. **빌드 & 배포** — `dev/docker.sh dev up [service...]`
   - 최초 실행 시:
     - 시스템 패키지 / Docker 설치
     - `/opt/llm-stack/deploy` 디렉토리 생성
     - `.env.dev`, nginx conf, redis sentinel conf, `docker-compose.yml` 자동 생성
   - 이후 실행: 지정 서비스만 재기동/재빌드

### 8.2 단축 명령

```bash
# 전체 dev 스택 기동
sudo /home/pps-nipa/jenkins/dev/docker.sh dev up

# 특정 서비스만 (예: STT + OCR)
sudo /home/pps-nipa/jenkins/dev/docker.sh dev up stt_api ocr_api

# 상태/로그
sudo /home/pps-nipa/jenkins/dev/docker.sh dev ps
sudo /home/pps-nipa/jenkins/dev/docker.sh dev logs backend
```

| 환경 | 스크립트 |
|------|---------|
| dev | `/home/pps-nipa/jenkins/dev/docker.sh dev ...` |
| stg | `/home/pps-nipa/jenkins/stg/docker.sh stg ...` (현재 `dev/docker.sh` 와 동일 로직) |
| prd | `/home/pps-nipa/jenkins/prd/docker.sh prd ...` |

---

## 9. Jenkins Job 구성 가이드 (권장)

워크스페이스에 다음 4개 Pipeline Job을 만들기를 권장합니다.

### 9.1 `00-clone-repos`
- Trigger: 수동 + Webhook(사내 Git push)
- Steps:
  ```groovy
  sh 'cd /workspace/dev && BRANCH=main ./git_clone.sh'
  ```

### 9.2 `10-download-models`
- Trigger: 수동(주기 또는 모델 갱신 시)
- Credentials: `HF_TOKEN` 바인딩
- Steps:
  ```groovy
  withCredentials([string(credentialsId: 'HF_TOKEN', variable: 'HF_TOKEN')]) {
    sh 'cd /workspace/dev && HF_TOKEN=$HF_TOKEN ./model_download.sh'
  }
  ```

### 9.3 `20-deploy-<env>` (예: `20-deploy-dev`)
- Parameter: `SERVICES` (string, 공백 구분, 비어있으면 전체)
- Steps:
  ```groovy
  sh """
    cd /workspace/dev
    sudo ./docker.sh dev up ${params.SERVICES}
  """
  ```

### 9.4 `90-health-check`
- 주기 실행(매 5분).
- 각 서비스 `/health` 호출, 실패 시 알람.

> Job 명은 환경별 prefix(`dev-`, `stg-`, `prd-`)로 통일하여 폴더로 관리.

---

## 10. 비즈니스 스택 구성요소 (`docker.sh` 가 자동 생성)

`docker.sh` 가 `.env.<env>` 와 `docker-compose.yml` 을 자동 생성합니다. 주요 서비스:

| 서비스 | 컨테이너명 | 내부 포트 | 역할 |
|--------|-----------|----------|------|
| `ingress_eai` | nginx | 80/443 | 외부 진입점 (EAI 도메인) |
| `ingress_llm` | nginx | 80/443 | 외부 진입점 (LLM 도메인) |
| `backend` | spring-boot | - | 비즈니스 백엔드 |
| `mic_speech_recognize` | - | 8017 | 마이크 화자 RMS 분할 |
| `speech_recognize` | - | 8016 | 화자 식별 (본 가이드) |
| `stt_api` | - | 8000 | WhisperX STT |
| `llm_api` | - | 8080 | LLM API (Gemma) |
| `ocr_api` | - | 8080 | OCR API |
| `mariadb_primary` / `mariadb_log` | - | 3306 | RDBMS |
| `redis_master` + sentinel x3 | - | 6379/26379 | Cache / pubsub |
| `minio` | - | 9000/9001 | 객체 저장소 |
| `milvus`, `etcd` | - | - | 벡터 DB |
| `elasticsearch` | - | 9200 | 검색 |
| `neo4j` | - | 7474/7687 | 그래프 |

> 실제 활성 서비스는 환경(`dev/stg/prd`)에 따라 다릅니다. `docker.sh list` 로 확인.

---

## 11. `.env.<env>` 핵심 변수

`docker.sh` 가 처음 실행될 때 `/opt/llm-stack/deploy/.env.<env>` 를 placeholder 로 생성합니다. 운영자는 **`[SET_ME]` 표시된 값**을 반드시 교체해야 합니다.

| 카테고리 | 변수 |
|----------|------|
| 도메인 | `DOMAIN_EAI`, `DOMAIN_LLM` |
| 이미지 | `IMG_BACKEND`, `IMG_STT_API`, `IMG_LLM_API`, `IMG_OCR_API`, `IMG_SPEECH_SR`, `IMG_MIC_SR`, `IMG_EMBEDDING` |
| 내부 URL | `STT_API_BASE`, `LLM_API_BASE`, `OCR_API_BASE`, `SPEECH_SR_BASE`, `MIC_SR_BASE` |
| 자원 경로 | `STT_RESOURCE_DIR_REL`, `SPEAKER_MODEL_REL`, `LLM_MODEL_DIR` |
| 자격증명 | `MARIADB_ROOT_PASSWORD`, `BIZ_DB_*`, `LOG_DB_*`, `MINIO_*`, `NEO4J_*` |
| RAG | `TENANT_ID`, `DOC_NAMESPACE_PREFIX`, `SEARCH_INDEX_PREFIX`, `EMBEDDING_MODEL_ID` |

---

## 12. TLS / 인증서

- 최초 실행 시 self-signed 인증서를 `/opt/llm-stack/deploy/nginx/tls/` 에 생성.
- 운영: Let's Encrypt 사용 시 `LE_DIR=/etc/letsencrypt`, `CERTBOT_WEBROOT=/var/www/certbot` 마운트.
- `docker.sh` 가 Let's Encrypt 인증서 존재 여부에 따라 nginx conf 의 인증서 경로를 자동 선택합니다.

---

## 13. 백업 / 영구화

- Jenkins 데이터: `jenkins_home` (named volume) — 백업 시 `docker run --rm -v jenkins_home:/data -v $(pwd):/backup busybox tar czf /backup/jenkins_home_$(date +%F).tgz /data`
- DB/Object Storage: `/opt/llm-stack/deploy/<service>_data` 의 named volume 또는 호스트 디렉토리
- 모델 가중치: 각 서비스 `src/resources/...` (재다운로드 가능)

---

## 14. 헬스 체크 / 모니터링

| 서비스 | 헬스 엔드포인트 |
|--------|-----------------|
| OCR | `http://<host>:6031/health` |
| LLM | `http://<host>:6001/health` |
| STT | `http://<host>:6002/health` |
| Speech | `http://<host>:6016/health` |

Jenkins 의 `90-health-check` Job 또는 외부 모니터링(Prometheus blackbox)에서 위 엔드포인트를 주기 조회.

---

## 15. 트러블슈팅

| 증상 | 조치 |
|------|------|
| Jenkins 컨테이너에서 `docker: command not found` | `/usr/bin/docker` 마운트 확인. compose 파일 재확인. |
| Git clone 실패 | SSH 키 마운트(`/root/.ssh/id_ed25519`) / known_hosts 확인 |
| 모델 다운로드 실패 (gated) | `HF_TOKEN` 설정 여부 확인 |
| 빌드 후 GPU 미인식 | 컨테이너 실행 시 `--gpus all` 필요 — `docker.sh` 의 compose 정의 확인 |
| 포트 충돌 | 환경 포트 베이스(6/9/8000) 충돌 — `.env.<env>` 의 서비스 포트 변경 |
| 8888 포트 외부 노출 위험 | Nginx 리버스 프록시 뒤로 두고 방화벽 제한 |

---

## 16. 관련 문서
- 개발 표준 → [`./development-standards.md`](./development-standards.md)
- 각 서비스 환경/표준
  - OCR: [`../dev/ocr/docs/`](../dev/ocr/docs/)
  - LLM: [`../dev/LLM/docs/`](../dev/LLM/docs/)
  - STT: [`../dev/stt/docs/`](../dev/stt/docs/)
  - Speech Recognize: [`../dev/speech_recognize/docs/`](../dev/speech_recognize/docs/)
