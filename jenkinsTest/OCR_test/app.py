"""
OCR Pipeline v2 — 데모 (Streamlit)

`jenkins/dev/ocr` FastAPI 백엔드 (`POST /ocr/process`, `GET /health`) 를 호출해
PDF·DOCX·HWP·HWPX 처리 결과를 "있어보이게" 시각화한다.

특징:
  - 파일 확장자 + 페이지당 평균 문자수로 처리 경로(디지털/스캔/DOCX/HWP/HWPX) 추론
  - 처리 파이프라인 단계 시각화 (사용된 단계 강조, 스킵된 단계는 흐림)
  - KPI 카드 + 페이지별 통계 차트(plotly) + 페이지별 카드/상세 뷰
  - Markdown 미리보기 + HTML 데이터-URI 다운로드(streamlit 일부 버전의
    `Failed to fetch dynamically imported module` 우회)
"""
from __future__ import annotations

import base64
import json
import os
from typing import Any
from urllib.parse import urljoin

import pandas as pd
import plotly.express as px
import requests
import streamlit as st


DEFAULT_API_BASE = os.getenv("OCR_API_BASE", "http://localhost:5005")
SUPPORTED_EXTENSIONS = ["pdf", "docx", "hwp", "hwpx"]
REQUEST_TIMEOUT = 600

PRESET_BASES: dict[str, str] = {
    "ocr_v1 container (:5005)": "http://localhost:5005",
    "local uvicorn (:8031)": "http://localhost:8031",
    "dev compose (:6005)": "http://localhost:6005",
    "stg compose (:9005)": "http://localhost:9005",
    "prd compose (:8005)": "http://localhost:8005",
}


# ==========================================
# 처리 경로 메타데이터 + 추론
# ==========================================
PATH_META: dict[str, dict[str, str]] = {
    "digital_pdf": {
        "label": "Digital PDF",
        "icon": "📄",
        "color": "#1E88E5",
        "desc": "글자가 이미 박혀있어 OCR 없이 직접 추출 (빠르고 정확)",
    },
    "scanned_pdf": {
        "label": "Scanned PDF",
        "icon": "🖼️",
        "color": "#FB8C00",
        "desc": "스캔본/이미지 PDF → PaddleOCR 로 글자 인식",
    },
    "docx": {
        "label": "DOCX",
        "icon": "📘",
        "color": "#43A047",
        "desc": "워드 XML 직접 파싱 (Heading·표·이미지 분리)",
    },
    "hwp": {
        "label": "HWP",
        "icon": "📕",
        "color": "#8E24AA",
        "desc": "LibreOffice → pyhwp → 직접 해부 3단 fallback",
    },
    "hwpx": {
        "label": "HWPX",
        "icon": "📗",
        "color": "#00897B",
        "desc": "ZIP 내부 XML 직접 파싱 (pageBreak 인식)",
    },
    "unknown": {
        "label": "기타",
        "icon": "📦",
        "color": "#757575",
        "desc": "",
    },
}


def infer_path(filename: str, results: list[dict[str, Any]]) -> str:
    """확장자 + 페이지당 평균 문자수 기반 처리 경로 추론."""
    ext = os.path.splitext(filename or "")[1].lower().lstrip(".")
    if ext == "pdf":
        total = sum(len((p.get("text") or "").strip()) for p in results)
        per_page = total / max(1, len(results))
        return "digital_pdf" if per_page > 200 else "scanned_pdf"
    if ext == "docx":
        return "docx"
    if ext == "hwp":
        return "hwp"
    if ext == "hwpx":
        return "hwpx"
    return "unknown"


# (단계 라벨, 설명, default-active 여부)
PIPELINE_STEPS: dict[str, list[tuple[str, str, bool]]] = {
    "digital_pdf": [
        ("① 파일 수신", "PDF 업로드 / 임시 저장", True),
        ("② 디지털 PDF 판별", "앞 3페이지 텍스트 길이 > 50자 ?", True),
        ("③ 표 위치 파악", "각 페이지의 표 사각형 영역 추출", True),
        ("④ 본문 + 표 정렬", "표를 원래 세로 위치에 끼워 넣기", True),
        ("⑤ Markdown 저장", "최종 .md 생성", True),
        ("OCR 엔진", "디지털 PDF 라 PaddleOCR 미사용", False),
    ],
    "scanned_pdf": [
        ("① 파일 수신", "PDF 업로드 / 임시 저장", True),
        ("② 스캔 PDF 판별", "텍스트 < 50자 → OCR 라우팅", True),
        ("③ 글자 영역 검출", "PaddleOCR detection 모델", True),
        ("④ 방향 보정 + 인식", "한글 모델로 텍스트 읽기 (conf > 0.5)", True),
        ("⑤ Markdown 저장", "최종 .md 생성", True),
    ],
    "docx": [
        ("① 파일 수신", "DOCX 업로드", True),
        ("② Word XML 파싱", "단락·표·이미지 분리", True),
        ("③ Heading 변환", "Heading1 → #, Heading2 → ##", True),
        ("④ 이미지 추출", "data/extracted_images/ 저장", True),
        ("⑤ Markdown 저장", "최종 .md 생성 (1-page 한계)", True),
    ],
    "hwp": [
        ("① 파일 수신", "HWP 업로드", True),
        ("② 1차: LibreOffice", "권장 경로 — PDF 변환 후 추출", True),
        ("③ 2차: pyhwp", "LibreOffice 없을 때 대안", False),
        ("④ 3차: HWP 직접 해부", "최후 수단 — 태그 67/71/72/77 파싱", False),
        ("⑤ Markdown 저장", "최종 .md 생성", True),
    ],
    "hwpx": [
        ("① 파일 수신", "HWPX 업로드", True),
        ("② 1차: LibreOffice", "권장 경로", True),
        ("③ 2차: ZIP→XML 직접", "내부 XML 직접 파싱 (fallback)", False),
        ("④ pageBreak 분할", "XML pageBreak 표시 위치에서 분리", True),
        ("⑤ Markdown 저장", "최종 .md 생성", True),
    ],
}


# ==========================================
# API 헬퍼
# ==========================================
def check_health(api_base: str) -> tuple[bool, Any]:
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
    try:
        url = urljoin(api_base + "/", markdown_url.lstrip("/"))
        r = requests.get(url, timeout=30)
        r.raise_for_status()
        return r.text
    except requests.RequestException:
        return None


# ==========================================
# 다운로드 (HTML data-URI 링크)
#  st.download_button 은 일부 streamlit 버전 + 외부 도메인에서
#  "Failed to fetch dynamically imported module" 가 발생하므로 우회.
# ==========================================
def download_link(
    data: bytes | str,
    filename: str,
    label: str,
    mime: str = "application/octet-stream",
) -> None:
    if isinstance(data, str):
        data = data.encode("utf-8")
    b64 = base64.b64encode(data).decode("ascii")
    href = f"data:{mime};base64,{b64}"
    st.markdown(
        f'''
        <a href="{href}" download="{filename}"
           style="display:inline-block;padding:0.5rem 1rem;border-radius:0.5rem;
                  background:#0E1117;color:#FAFAFA;text-decoration:none;
                  border:1px solid #4C9AFF;font-size:0.9rem;
                  margin-right:8px; margin-top:4px;">
          {label}
        </a>
        ''',
        unsafe_allow_html=True,
    )


# ==========================================
# CSS
# ==========================================
def inject_css() -> None:
    st.markdown(
        """
        <style>
        .ocr-hero {
            background: linear-gradient(135deg, #0F2027 0%, #203A43 55%, #2C5364 100%);
            color: #fff;
            padding: 26px 30px;
            border-radius: 18px;
            margin-bottom: 14px;
            box-shadow: 0 6px 18px rgba(15,32,39,0.18);
        }
        .ocr-hero h1 { margin: 0; font-size: 30px; font-weight: 700; letter-spacing: -0.4px; }
        .ocr-hero p  { margin: 6px 0 0 0; opacity: 0.86; font-size: 15px; line-height: 1.5; }
        .ocr-kpi-row { display: flex; gap: 12px; margin-top: 18px; flex-wrap: wrap; }
        .ocr-kpi {
            flex: 1 1 140px; background: rgba(255,255,255,0.10);
            padding: 12px 16px; border-radius: 12px;
            border: 1px solid rgba(255,255,255,0.10);
            min-width: 130px;
        }
        .ocr-kpi b { font-size: 22px; font-weight: 700; display: block; }
        .ocr-kpi span { font-size: 12px; opacity: 0.78; }

        .ocr-result-card {
            background: white;
            border: 1px solid #E2E8F0;
            border-radius: 14px;
            padding: 18px 22px;
            margin-bottom: 14px;
            box-shadow: 0 1px 4px rgba(15,23,42,0.04);
        }
        .ocr-result-card-head {
            display: flex; align-items: center; justify-content: space-between;
            flex-wrap: wrap; gap: 10px;
        }
        .ocr-filename {
            font-size: 19px; font-weight: 600; color: #0F172A;
        }
        .ocr-badge {
            display: inline-block; padding: 5px 14px;
            border-radius: 999px; font-size: 13px; font-weight: 700;
            color: white; letter-spacing: 0.2px;
        }
        .ocr-path-desc { color: #475569; font-size: 13px; margin-top: 4px; }

        .ocr-step {
            background: #F1F5F9;
            border-radius: 10px;
            border-left: 4px solid #CBD5E1;
            padding: 10px 14px;
            height: 100%;
            min-height: 96px;
            transition: all 0.15s;
        }
        .ocr-step.active {
            background: #E0F2FE;
            border-left-color: #0284C7;
        }
        .ocr-step.skipped {
            opacity: 0.5;
            background: #F8FAFC;
        }
        .ocr-step-title {
            font-weight: 700; font-size: 13.5px; color: #0F172A;
            margin-bottom: 4px;
        }
        .ocr-step-desc { font-size: 12px; color: #475569; line-height: 1.45; }
        </style>
        """,
        unsafe_allow_html=True,
    )


# ==========================================
# Hero
# ==========================================
def render_hero() -> None:
    st.markdown(
        """
        <div class="ocr-hero">
            <h1>📄 OCR Pipeline v2</h1>
            <p><b>"OCR은 마지막 수단."</b> &nbsp;글자가 이미 박혀있으면 그냥 꺼냅니다. &nbsp;
            PDF · DOCX · HWP · HWPX → Markdown</p>
            <div class="ocr-kpi-row">
                <div class="ocr-kpi"><b>4</b><span>지원 포맷</span></div>
                <div class="ocr-kpi"><b>3-stage</b><span>HWP fallback</span></div>
                <div class="ocr-kpi"><b>📍 표 위치 보존</b><span>본문 사이 자동 재배치</span></div>
                <div class="ocr-kpi"><b>🛡️ On-Prem</b><span>완전 자체 호스팅</span></div>
            </div>
        </div>
        """,
        unsafe_allow_html=True,
    )


# ==========================================
# Pipeline steps (가로 카드 5칸)
# ==========================================
def render_pipeline_steps(path: str) -> None:
    steps = PIPELINE_STEPS.get(path)
    if not steps:
        st.info("처리 경로를 추론하지 못했습니다.")
        return

    st.markdown("### 🔄 이 파일이 거친 처리 경로")
    meta = PATH_META.get(path, PATH_META["unknown"])
    st.caption(
        f"<span class='ocr-badge' style='background:{meta['color']};'>{meta['icon']} {meta['label']}</span> "
        f"&nbsp; {meta['desc']}",
        unsafe_allow_html=True,
    )

    n = len(steps)
    cols = st.columns(n)
    for col, (title, desc, active) in zip(cols, steps):
        cls = "active" if active else "skipped"
        col.markdown(
            f"""
            <div class="ocr-step {cls}">
                <div class="ocr-step-title">{title}</div>
                <div class="ocr-step-desc">{desc}</div>
            </div>
            """,
            unsafe_allow_html=True,
        )


# ==========================================
# KPI / 헤더 카드
# ==========================================
def render_kpis(resp: dict[str, Any], path: str) -> None:
    meta = PATH_META.get(path, PATH_META["unknown"])
    results = resp.get("results", []) or []
    total_tables = sum(len(p.get("tables") or []) for p in results)
    total_images = sum(len(p.get("images") or []) for p in results)
    total_chars = sum(len((p.get("text") or "").strip()) for p in results)

    st.markdown(
        f"""
        <div class="ocr-result-card">
          <div class="ocr-result-card-head">
            <div>
              <span class="ocr-filename">📄 {resp.get('filename','-')}</span>
              <span class="ocr-badge" style="background:{meta['color']}; margin-left:10px;">
                {meta['icon']} {meta['label']}
              </span>
            </div>
            <div style="font-size:13px; color:#475569;">
              doc_id <code>{resp.get('doc_id') if resp.get('doc_id') is not None else '-'}</code>
              · mode <code>{resp.get('mode','-')}</code>
            </div>
          </div>
          <div class="ocr-path-desc">{meta['desc']}</div>
        </div>
        """,
        unsafe_allow_html=True,
    )

    c1, c2, c3, c4, c5 = st.columns(5)
    c1.metric("📑 페이지 수", resp.get("page_count", 0))
    c2.metric("✏️ 총 문자수", f"{total_chars:,}")
    c3.metric("📊 총 표 수", total_tables)
    c4.metric("🖼️ 총 이미지 수", total_images)
    c5.metric("⏱️ 처리 시간", f"{resp.get('processed_time',0):.2f}s")


# ==========================================
# 페이지별 통계 차트
# ==========================================
def render_page_stats(results: list[dict[str, Any]]) -> None:
    if not results:
        return
    df = pd.DataFrame(
        [
            {
                "page": str(p.get("page_num", i + 1)),
                "문자수": len((p.get("text") or "").strip()),
                "표 수": len(p.get("tables") or []),
                "이미지 수": len(p.get("images") or []),
            }
            for i, p in enumerate(results)
        ]
    )
    if df.empty:
        return

    c1, c2 = st.columns(2)
    with c1:
        fig = px.bar(
            df, x="page", y="문자수",
            title="페이지별 문자 수",
            color_discrete_sequence=["#4C9AFF"],
        )
        fig.update_layout(
            height=320, template="plotly_white", showlegend=False,
            margin=dict(l=10, r=10, t=40, b=10),
            xaxis=dict(title=""),
        )
        st.plotly_chart(fig, use_container_width=True)
    with c2:
        long_df = df.melt(
            id_vars="page",
            value_vars=["표 수", "이미지 수"],
            var_name="종류",
            value_name="개수",
        )
        fig = px.bar(
            long_df, x="page", y="개수", color="종류", barmode="group",
            color_discrete_map={"표 수": "#36B37E", "이미지 수": "#FF6B6B"},
            title="페이지별 표 / 이미지 수",
        )
        fig.update_layout(
            height=320, template="plotly_white",
            margin=dict(l=10, r=10, t=40, b=10),
            xaxis=dict(title=""),
            legend=dict(orientation="h", yanchor="bottom", y=1.02, xanchor="right", x=1),
        )
        st.plotly_chart(fig, use_container_width=True)


# ==========================================
# 페이지 상세 (selectbox)
# ==========================================
def render_page_detail(results: list[dict[str, Any]], api_base: str) -> None:
    if not results:
        st.info("페이지 결과가 없습니다.")
        return

    labels = [
        f"Page {p.get('page_num', i + 1)} · {len((p.get('text') or '').strip()):,}자 · "
        f"표 {len(p.get('tables') or [])} · 이미지 {len(p.get('images') or [])}"
        for i, p in enumerate(results)
    ]
    idx = st.selectbox(
        "페이지 선택",
        options=range(len(results)),
        format_func=lambda i: labels[i],
    )
    page = results[idx]
    text = (page.get("text") or "").strip()
    tables = page.get("tables") or []
    images = page.get("images") or []

    body_tab, table_tab, image_tab = st.tabs(
        [f"📝 본문 ({len(text):,}자)", f"📊 표 ({len(tables)})", f"🖼️ 이미지 ({len(images)})"]
    )

    with body_tab:
        if text:
            view_mode = st.radio(
                "표시", ["Markdown rendered", "Raw text"],
                horizontal=True, label_visibility="collapsed",
                key=f"view_{idx}",
            )
            if view_mode == "Markdown rendered":
                with st.container(height=500, border=True):
                    st.markdown(text)
            else:
                st.text_area("raw", text, height=500, label_visibility="collapsed", key=f"raw_{idx}")
        else:
            st.info("추출된 본문이 없습니다.")

    with table_tab:
        if not tables:
            st.info("이 페이지에는 표가 없습니다.")
        for i, tbl in enumerate(tables, start=1):
            st.markdown(f"**표 {i}**")
            st.markdown(tbl)
            st.divider()

    with image_tab:
        if not images:
            st.info("이 페이지에는 이미지가 없습니다.")
        cols_per_row = 3
        for row_start in range(0, len(images), cols_per_row):
            row_imgs = images[row_start : row_start + cols_per_row]
            cols = st.columns(len(row_imgs))
            for col, img_path in zip(cols, row_imgs):
                url = (
                    urljoin(api_base + "/", img_path.lstrip("/"))
                    if isinstance(img_path, str) and img_path.startswith("/")
                    else img_path
                )
                try:
                    col.image(url, caption=os.path.basename(str(img_path)), use_container_width=True)
                except Exception:
                    col.markdown(f"- `{img_path}`")


# ==========================================
# 앱 본체
# ==========================================
def main() -> None:
    st.set_page_config(
        page_title="OCR Pipeline v2 — Demo",
        page_icon="📄",
        layout="wide",
    )
    inject_css()
    render_hero()

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

        if st.button("🩺 헬스 체크", use_container_width=True):
            ok, info = check_health(api_base)
            if ok:
                st.success("서버 정상")
                st.json(info)
            else:
                st.error(f"서버 응답 없음\n\n{info}")
                st.info(
                    "확인 사항\n"
                    "- `docker ps | grep ocr_v1`\n"
                    "- `docker run -d -p 5005:5005 -e APP_PORT=5005 --gpus all "
                    "--name ocr_v1 pps/ocr:v0.0.1`"
                )

        st.divider()
        st.subheader("📂 지원 포맷")
        st.markdown(
            " · ".join(
                f"`{PATH_META[k]['icon']} .{k.replace('_pdf','')}`"
                for k in ["digital_pdf", "docx", "hwp", "hwpx"]
            )
        )
        st.caption("PDF는 디지털/스캔을 자동 판별해 다른 경로로 처리합니다.")

        st.divider()
        st.subheader("🔌 엔드포인트")
        st.code(
            f"POST {api_base}/ocr/process\nGET  {api_base}/health",
            language="bash",
        )

    # ----- Upload -----
    st.markdown("### 1️⃣ 문서 업로드")
    uploaded = st.file_uploader(
        "PDF / DOCX / HWP / HWPX 파일을 업로드하세요",
        type=SUPPORTED_EXTENSIONS,
        accept_multiple_files=False,
        label_visibility="collapsed",
    )

    col_run, col_clear, _ = st.columns([1, 1, 5])
    run = col_run.button(
        "🚀 OCR 실행",
        type="primary",
        disabled=uploaded is None,
        use_container_width=True,
    )
    if col_clear.button("🧹 결과 초기화", use_container_width=True):
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
        st.toast(
            f"처리 완료 — {resp.get('page_count', 0)} 페이지, "
            f"{resp.get('processed_time', 0):.2f}초",
            icon="✅",
        )

    # ----- Result -----
    resp = st.session_state.get("ocr_resp")
    if not resp:
        st.info("파일을 업로드하고 **🚀 OCR 실행** 버튼을 눌러주세요.")
        return

    results: list[dict[str, Any]] = resp.get("results", []) or []
    path = infer_path(resp.get("filename", ""), results)
    md_text: str = st.session_state.get("ocr_md", "") or ""

    st.markdown("### 2️⃣ 결과 요약")
    render_kpis(resp, path)

    render_pipeline_steps(path)

    if len(results) > 1:
        st.markdown("### 📊 페이지별 통계")
        render_page_stats(results)

    st.markdown("### 3️⃣ 결과 자세히 보기")
    tab_md, tab_pages, tab_json = st.tabs(
        ["📝 Markdown 통합 뷰", "📑 페이지별 상세", "🔧 Raw JSON"]
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
            base_name = os.path.splitext(resp.get("filename", "result"))[0]
            download_link(
                md_text,
                filename=f"{base_name}_result.md",
                label="📥 Markdown 다운로드",
                mime="text/markdown",
            )
        else:
            st.warning(
                "Markdown 파일을 서버에서 가져오지 못했습니다. "
                f"`{resp.get('markdown_url', '')}` 경로를 확인해주세요."
            )

    with tab_pages:
        render_page_detail(results, api_base)

    with tab_json:
        st.json(resp)
        base_name = os.path.splitext(resp.get("filename", "result"))[0]
        download_link(
            json.dumps(resp, ensure_ascii=False, indent=2),
            filename=f"{base_name}_result.json",
            label="📥 JSON 다운로드",
            mime="application/json",
        )


if __name__ == "__main__":
    main()
