# OCR Pipeline Streamlit Demo

`jenkins/dev/ocr` (= PoC `ocr_v1` 컨테이너) 의 FastAPI 백엔드를 호출해서
**활자체 문서(PDF / DOCX / HWP / HWPX)** OCR 결과를 시각적으로 확인하는 데모.

- 메트릭: 파일명 · 모드 · 페이지 수 · 처리 시간
- 📝 Markdown 미리보기 (렌더링 + 원본 비교, `/static`에서 직접 fetch)
- 📑 페이지별 보기 (페이지 선택 → 본문/표/이미지 탭)
- 🧾 Raw JSON
- Markdown / JSON 결과 다운로드

## 구성

| 컴포넌트 | 위치 / 컨테이너 | 포트 |
|----------|----------------|------|
| Streamlit | host 프로세스 (venv: `.venv/`) | **8051** |
| OCR API | `ocr_v1` 컨테이너 (`pps/ocr:v0.0.1`) | `5005 → 5005` |

## 실행

### 1) OCR FastAPI 컨테이너 (이미 떠있으면 스킵)

```bash
cd ~/PoC/fish/ocr
docker rm -f ocr_v1 2>/dev/null
docker build -t pps/ocr:v0.0.1 -f Dockerfile .
docker run -d -p 5005:5005 -e APP_PORT=5005 --restart always \
  --gpus all \
  --name ocr_v1 pps/ocr:v0.0.1

curl http://localhost:5005/health
```

응답 예:
```json
{
  "status": "ok",
  "libreoffice_available": true,
  "supported_formats": [".pdf", ".docx", ".hwp", ".hwpx"],
  "mode": "printed",
  "llm_correction": false
}
```

### 2) Streamlit

```bash
cd /home/pps-nipa/jenkins/jenkinsTest/OCR_test
python3 -m venv .venv     # 처음 1회만
.venv/bin/pip install -r requirements.txt

pkill -f "streamlit run app.py"   # 기존 인스턴스 정리
nohup .venv/bin/streamlit run app.py > /tmp/streamlit_ocr.log 2>&1 &
```

UFW 8051 이미 열림. 라이브 로그: `tail -f /tmp/streamlit_ocr.log`

## 접속

| URL | 비고 |
|-----|------|
| http://localhost:8051 | 호스트 본인 |
| http://192.168.0.3:8051 | LAN |
| http://niq.kro.kr:8051 | 외부 (라우터 NAT 포워딩 시) |

## 사용 흐름

1. **사이드바 환경 프리셋** 선택 — 기본 `ocr_v1 container (:5005)`
2. **헬스 체크** → `libreoffice_available: true`, 지원 포맷 확인
3. **1) 문서 업로드** — `.pdf / .docx / .hwp / .hwpx`
4. **🚀 OCR 실행** → 대용량 PDF는 수 분 소요
5. **결과 확인**
   - 📝 Markdown 탭 — 좌측 렌더링 / 우측 원본 비교, `_result.md` 다운로드
   - 📑 페이지별 탭 — 페이지 선택 → 본문/표/이미지(있을 시 `/static`으로 자동 로드)
   - 🧾 Raw JSON 탭 — `OCRResponse` 원본, JSON 다운로드

## 환경 프리셋

사이드바 셀렉터로 즉시 전환 가능:

| 프리셋 | URL | 비고 |
|--------|-----|------|
| ocr_v1 container | `http://localhost:5005` | 현재 PoC (기본) |
| local uvicorn | `http://localhost:8031` | 코드 기본값 `OCR_PORT` |
| dev compose | `http://localhost:6005` | `jenkins/dev/docker.sh dev` |
| stg compose | `http://localhost:9005` | `docker.sh stg` |
| prd compose | `http://localhost:8005` | `docker.sh prd` |

`OCR_API_BASE` 환경변수로도 지정 가능:
```bash
OCR_API_BASE=http://10.x.x.x:5005 streamlit run app.py
```

## API 스펙 요약

| 메서드 | 경로 | 설명 |
|--------|------|------|
| `POST` | `/ocr/process` | multipart `file` → `OCRResponse { filename, mode, processed_time, page_count, markdown_url, results[] }` |
| `GET` | `/health` | LibreOffice 가용 여부 / 지원 포맷 |
| `GET` | `/static/3_final_markdown/<base>_result.md` | 변환 결과 .md 다운로드 |

## 트러블슈팅

| 증상 | 원인 | 조치 |
|------|------|------|
| `Connection refused` | `ocr_v1` 미실행 | `docker ps \| grep ocr_v1` 확인 후 재기동 |
| `libreoffice_available: false` | HWP/HWPX/DOCX 변환 불가 | 컨테이너에 LibreOffice 누락 (Dockerfile 점검) |
| 500 에러 (HWP) | LibreOffice 변환 타임아웃 | `src/common/config.py` `LIBREOFFICE_TIMEOUT` 상향 |
| Markdown 미리보기 빈칸 | `/static` 경로 401/404 | 사이드바 URL과 백엔드 컨테이너 매핑 일치 확인 |

## 참고

- 백엔드 docs: [`jenkins/dev/ocr/docs/development-environment.md`](../../jenkins/dev/ocr/docs/development-environment.md)
- 백엔드 엔트리포인트: `jenkins/dev/ocr/src/api_server.py`
- 외부 Swagger: http://niq.kro.kr:5005/docs (포워딩 시)
