"""
OCR Pipeline 결과 확인용 Streamlit 데모

`jenkins/dev/ocr` 의 FastAPI(`POST /ocr/process`, `GET /health`)를
호출해서 활자체 문서(PDF/DOCX/HWP/HWPX) OCR 결과를 시각적으로 보여준다.

실행:
    streamlit run app.py
"""
from __future__ import annotations

import io
import json
import os
from typing import Any
from urllib.parse import urljoin

import requests
import streamlit as st


DEFAULT_API_BASE = os.getenv("OCR_API_BASE", "http://localhost:5005")
SUPPORTED_EXTENSIONS = ["pdf", "docx", "hwp", "hwpx"]
REQUEST_TIMEOUT = 600

# 환경별 빠른 선택 프리셋
#   - ocr_v1 컨테이너: PoC/fish/ocr 에서 `docker run -p 5005:5005 ... pps/ocr:v0.0.1`
#   - local uvicorn:   src/common/config.py 의 OCR_PORT 기본값 8031
#   - dev/stg/prd:     jenkins/dev/docker.sh 의 포트 규칙 (ocr_api = PORT_BASE + 5)
PRESET_BASES: dict[str, str] = {
    "ocr_v1 container (:5005)": "http://localhost:5005",
    "local uvicorn (:8031)": "http://localhost:8031",
    "dev compose (:6005)": "http://localhost:6005",
    "stg compose (:9005)": "http://localhost:9005",
    "prd compose (:8005)": "http://localhost:8005",
}


# ==========================================
# API 헬퍼
# ==========================================
def check_health(api_base: str) -> tuple[bool, dict[str, Any] | str]:
    try:
        r = requests.get(urljoin(api_base + "/", "health"), timeout=10)
        r.raise_for_status()
        return True, r.json()
    except requests.RequestException as e:
        return False, str(e)


def call_ocr(api_base: str, filename: str, content: bytes, mime: str) -> dict[str, Any]:
    files = {"file": (filename, content, mime or "application/octet-stream")}
    r = requests.post(
        urljoin(api_base + "/", "ocr/process"),
        files=files,
        timeout=REQUEST_TIMEOUT,
    )
    r.raise_for_status()
    return r.json()


def fetch_markdown(api_base: str, markdown_url: str) -> str | None:
    """`markdown_url` 은 `/static/...` 같은 상대 경로로 내려옴."""
    try:
        url = urljoin(api_base + "/", markdown_url.lstrip("/"))
        r = requests.get(url, timeout=30)
        r.raise_for_status()
        return r.text
    except requests.RequestException:
        return None


# ==========================================
# 표시 헬퍼
# ==========================================
def render_metrics(resp: dict[str, Any]) -> None:
    c1, c2, c3, c4 = st.columns(4)
    c1.metric("파일명", resp.get("filename", "-"))
    c2.metric("처리 모드", resp.get("mode", "-"))
    c3.metric("페이지 수", resp.get("page_count", 0))
    c4.metric("처리 시간(초)", f"{resp.get('processed_time', 0):.2f}")


def render_page_view(results: list[dict[str, Any]], api_base: str) -> None:
    if not results:
        st.info("페이지 결과가 없습니다.")
        return

    labels = [f"Page {p.get('page_num', i + 1)}" for i, p in enumerate(results)]
    pick = st.selectbox("페이지 선택", options=range(len(results)), format_func=lambda i: labels[i])
    page = results[pick]

    text = (page.get("text") or "").strip()
    tables = page.get("tables") or []
    images = page.get("images") or []

    st.caption(f"텍스트 {len(text):,}자 · 표 {len(tables)}개 · 이미지 {len(images)}개")

    tabs = st.tabs(["본문", f"표 ({len(tables)})", f"이미지 ({len(images)})"])

    with tabs[0]:
        if text:
            st.text_area("본문 텍스트", text, height=420, label_visibility="collapsed")
        else:
            st.info("추출된 본문이 없습니다.")

    with tabs[1]:
        if not tables:
            st.info("이 페이지에는 표가 없습니다.")
        for i, tbl in enumerate(tables, start=1):
            st.markdown(f"**표 {i}**")
            st.markdown(tbl)
            st.divider()

    with tabs[2]:
        if not images:
            st.info("이 페이지에는 이미지가 없습니다.")
        for img_path in images:
            url = urljoin(api_base + "/", img_path.lstrip("/")) if img_path.startswith("/") else img_path
            try:
                st.image(url, caption=img_path, use_column_width=True)
            except Exception:
                st.markdown(f"- `{img_path}`")


# ==========================================
# 앱 본체
# ==========================================
def main() -> None:
    st.set_page_config(
        page_title="OCR Pipeline Demo",
        page_icon="📄",
        layout="wide",
    )

    st.title("📄 OCR Pipeline 결과 뷰어")
    st.caption(
        "`jenkins/dev/ocr` FastAPI 백엔드를 호출해 활자체 문서(PDF/DOCX/HWP/HWPX) "
        "OCR 결과를 확인합니다."
    )

    # ----- Sidebar -----
    with st.sidebar:
        st.header("⚙️ 서버 설정")

        preset_labels = list(PRESET_BASES.keys())
        default_idx = next(
            (i for i, k in enumerate(preset_labels) if PRESET_BASES[k] == DEFAULT_API_BASE),
            0,
        )
        preset = st.selectbox("환경 프리셋", preset_labels, index=default_idx)
        api_base = st.text_input(
            "API Base URL",
            value=PRESET_BASES[preset],
            help="docker.sh 포트 규칙: dev=6000번대 / stg=9000번대 / prd=8000번대 (ocr_api는 +5)",
        ).rstrip("/")

        if st.button("헬스 체크", use_container_width=True):
            ok, info = check_health(api_base)
            if ok:
                st.success("서버 정상")
                st.json(info)
            else:
                st.error(f"서버 응답 없음\n\n{info}")
                st.info(
                    "**확인 사항**\n"
                    "- `localhost:5005` → `docker ps | grep ocr_v1` 로 컨테이너 떠 있는지\n"
                    "- 안 떠 있으면 `~/PoC/fish/ocr` 에서 `docker run -d -p 5005:5005 "
                    "-e APP_PORT=5005 --gpus all --name ocr_v1 pps/ocr:v0.0.1`\n"
                    "- 원격 서버라면 호스트/방화벽 확인"
                )

        st.divider()
        st.subheader("지원 포맷")
        st.markdown(" · ".join(f"`.{e}`" for e in SUPPORTED_EXTENSIONS))

        st.divider()
        st.subheader("엔드포인트")
        st.code(f"POST {api_base}/ocr/process\nGET  {api_base}/health", language="bash")

    # ----- Upload -----
    st.subheader("1) 문서 업로드")
    uploaded = st.file_uploader(
        "PDF / DOCX / HWP / HWPX 파일을 업로드하세요",
        type=SUPPORTED_EXTENSIONS,
        accept_multiple_files=False,
    )

    col_run, col_clear = st.columns([1, 5])
    run = col_run.button("🚀 OCR 실행", type="primary", disabled=uploaded is None)
    if col_clear.button("결과 초기화"):
        st.session_state.pop("ocr_resp", None)
        st.session_state.pop("ocr_md", None)
        st.rerun()

    if run and uploaded is not None:
        with st.spinner(f"`{uploaded.name}` 처리 중... (대용량 PDF는 수 분 소요)"):
            try:
                resp = call_ocr(api_base, uploaded.name, uploaded.getvalue(), uploaded.type)
            except requests.HTTPError as e:
                st.error(f"API 오류 ({e.response.status_code}): {e.response.text}")
                return
            except requests.RequestException as e:
                st.error(f"요청 실패: {e}")
                return

        st.session_state["ocr_resp"] = resp
        md_text = fetch_markdown(api_base, resp.get("markdown_url", "")) or ""
        st.session_state["ocr_md"] = md_text
        st.success(f"처리 완료 — {resp.get('page_count', 0)} 페이지, {resp.get('processed_time', 0):.2f}초")

    # ----- Result -----
    resp = st.session_state.get("ocr_resp")
    if not resp:
        st.info("파일을 업로드하고 **OCR 실행** 버튼을 눌러주세요.")
        return

    st.subheader("2) 처리 결과")
    render_metrics(resp)

    md_text: str = st.session_state.get("ocr_md", "") or ""
    results: list[dict[str, Any]] = resp.get("results", [])

    tab_md, tab_pages, tab_json = st.tabs(
        ["📝 Markdown 미리보기", "📑 페이지별 보기", "🔧 Raw JSON"]
    )

    with tab_md:
        if md_text:
            c1, c2 = st.columns([1, 1])
            with c1:
                st.markdown("**렌더링 결과**")
                with st.container(height=600, border=True):
                    st.markdown(md_text)
            with c2:
                st.markdown("**원본 Markdown**")
                st.text_area(
                    "Markdown 원문",
                    md_text,
                    height=600,
                    label_visibility="collapsed",
                )
            st.download_button(
                "📥 Markdown 다운로드",
                data=md_text.encode("utf-8"),
                file_name=f"{os.path.splitext(resp.get('filename', 'result'))[0]}_result.md",
                mime="text/markdown",
            )
        else:
            st.warning(
                "Markdown 파일을 서버에서 가져오지 못했습니다. "
                f"`{resp.get('markdown_url', '')}` 경로를 확인해주세요."
            )

    with tab_pages:
        render_page_view(results, api_base)

    with tab_json:
        st.json(resp)
        st.download_button(
            "📥 JSON 다운로드",
            data=json.dumps(resp, ensure_ascii=False, indent=2).encode("utf-8"),
            file_name=f"{os.path.splitext(resp.get('filename', 'result'))[0]}_result.json",
            mime="application/json",
        )


if __name__ == "__main__":
    main()
