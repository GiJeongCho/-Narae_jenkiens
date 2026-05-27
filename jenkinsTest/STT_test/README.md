# STT + 화자 식별 Streamlit Demo

`jenkins/dev/stt` (Whisper) 와 `jenkins/dev/speech_recognize` (ERes2Net) 두 FastAPI 백엔드를
한 화면에서 검증하는 데모 앱.

- **탭 1️⃣ STT (Whisper)** — 음성을 텍스트로 변환 (+ 화자 분리 `SPEAKER_xx`, 활성화 시)
- **탭 2️⃣ 화자 식별** — STT 결과(segments)와 같은 오디오를 보내, 각 발화 구간이
  사내 등록 직원 중 누구인지 매칭 (`김나연 / 김루아 / 김수현 / 이용범 / 조기정`)
- **탭 🧾 Raw JSON** — 두 응답 원본 동시 보기

## 구성

| 컴포넌트 | 위치 / 컨테이너 | 포트 |
|----------|----------------|------|
| Streamlit | host 프로세스 (venv: `.venv/`) | **8052** |
| STT (Whisper) | `stt` 컨테이너 (`pps/whisper-stt:v0.0.1`) — **GPU 3 격리** | `5002 → 5002` |
| Speech Recognize | `speech_recognize_dev` 컨테이너 (`pps/speech_recognize:v0.0.1`) | `6003 → 5003` |
| ERes2Net 모델 | `jenkins/dev/speech_recognize/src/resoursces/models/iic/...` (호스트 마운트) | - |
| 직원 enrollment | `jenkins/dev/speech_recognize/src/resoursces/employee/` | - |

## 실행

### 1) 백엔드 컨테이너 (이미 떠있으면 스킵)

```bash
# STT (GPU 3 격리 - OOM 방지)
docker rm -f stt
docker run -d -p 5002:5002 -e APP_PORT=5002 \
  --gpus '"device=3"' --restart always --name stt \
  pps/whisper-stt:v0.0.1

# Speech Recognize (모델 마운트 필수, dev compose 네트워크 합류)
docker rm -f speech_recognize_dev
docker run -d --name speech_recognize_dev --restart unless-stopped \
  --gpus all --network deploy_app_net -p 6003:5003 \
  -e APP_PORT=5003 \
  -e SPEAKER_MODEL_PATH=/app/src/resoursces/models/iic/speech_eres2net_base_sv_zh-cn_3dspeaker_16k \
  -v /home/pps-nipa/jenkins/dev/speech_recognize/src/resoursces/models:/app/src/resoursces/models:ro \
  pps/speech_recognize:v0.0.1
docker network connect deploy_data_net speech_recognize_dev

# 헬스 확인
curl http://localhost:5002/health
curl http://localhost:6003/health
```

### 2) Streamlit (이미 실행 중)

```bash
cd /home/pps-nipa/jenkins/jenkinsTest/STT_test
python3 -m venv .venv    # 처음 1회만
.venv/bin/pip install -r requirements.txt

# 기존 인스턴스 정리 후 백그라운드 기동
pkill -f "streamlit run app.py"
nohup .venv/bin/streamlit run app.py > /tmp/streamlit_stt.log 2>&1 &
```

UFW 8052 이미 열림. 라이브 로그: `tail -f /tmp/streamlit_stt.log`

## 접속

| URL | 비고 |
|-----|------|
| http://localhost:8052 | 호스트 본인 |
| http://192.168.0.3:8052 | LAN |
| http://niq.kro.kr:8052 | 외부 (라우터 NAT 포워딩 시) |

## 사용 흐름

1. **사이드바 헬스 체크** — 두 서버 모두 OK 확인
   - STT: `{"status":"ok","models":{"device":"cuda","whisper_model":"large-v3", ...}}`
   - SR:  `{"status":"healthy"}`
2. **🎵 오디오 소스 선택** (두 탭 공통)
   - "직접 업로드" 또는 "예시 파일에서 선택"
   - 예시는 `example_data/` 폴더에 둔 파일이 자동 노출
   - 미리듣기 + 파일명/크기/MIME 표시
3. **1️⃣ STT 탭**
   - 옵션: `language` (ko/en/ja/zh) · `diarize` (체크) · `batch_size` (16) · `beam_size` (5) · `min/max speakers`
   - 🚀 STT 실행 → 진행률 바 + 완료 후 segments 표 (start/end/duration/speaker/text) + 합본 transcript
   - JSON 다운로드 가능
4. **2️⃣ 화자 식별 탭**
   - 임계값 `threshold` (기본 0.2, ERes2Net 코사인 유사도)
   - 1번 탭의 결과를 자동으로 받아 호출 (`POST /v1/recognize`)
   - 완료 후 매칭된 인물 강조 + 표 (start/end/stt_speaker/matched_speaker/score/text)
5. **🧾 Raw JSON** — 두 응답 원본 동시 표시

## 옵션 기본값 (백엔드 docs 일치)

| 옵션 | 기본값 | 출처 |
|------|--------|------|
| STT `batch_size` | 16 | WhisperX 기본 |
| STT `beam_size` | 5 | WhisperX 기본 |
| STT `diarize` | true | docs |
| STT `language` | ko | 사내 환경 |
| SR `threshold` | 0.2 | `speech_recognize/v1/router.py` |

## 트러블슈팅

| 증상 | 원인 | 조치 |
|------|------|------|
| `Port 8052 is not available` | 이미 떠있는 streamlit | `pkill -f "streamlit run app.py"` 후 재기동 |
| STT `CUDA out of memory` | GPU 0 점유 + STT가 cuda:0에 로드 | `--gpus '"device=3"'` 격리 후 재기동 |
| STT `diarization_enabled: false` | pyannote gated repo 401 | `-e HF_TOKEN=hf_xxxx` 로 재기동 (화자 매칭은 영향 없음) |
| SR `progress: float` 에러 | `JobInfo.progress`가 float인데 dict로 처리 | `app.py` `normalize_progress()`로 해결됨 |
| SR `No 'chunks' or 'segments'` | 잘못된 JSON 업로드 | 1번 탭 결과를 그대로 보내야 함 (앱이 자동 처리) |
| 매칭 결과가 모두 `unknown` | threshold 너무 높음 / enrollment 짧음 | threshold 0.1~0.15로 낮추거나 enrollment 보강 |

## 참고

- STT 백엔드 docs: [`jenkins/dev/stt/docs/development-environment.md`](../../jenkins/dev/stt/docs/development-environment.md)
- 화자식별 백엔드 docs: [`jenkins/dev/speech_recognize/docs/development-environment.md`](../../jenkins/dev/speech_recognize/docs/development-environment.md)
- 외부 Swagger:
  - STT: http://niq.kro.kr:5002/docs
  - SR:  http://niq.kro.kr:6003/docs
