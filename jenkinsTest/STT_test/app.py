"""
STT(Whisper) + Speech Recognize(직원 화자 식별) 통합 Streamlit 데모.

두 개의 FastAPI 백엔드를 한 화면에서 검증한다.

  - STT             : Whisper(stt 컨테이너)  -- 음성 → 텍스트 + (가능 시) 화자 분리(SPEAKER_xx)
  - Speech Recognize: ERes2Net(speech_recognize 컨테이너)
                      -- STT의 segments + 사내 직원 enrollment 음성을 비교해
                         각 발화 구간이 누구의 목소리인지 식별

탭1 = STT 단독, 탭2 = (STT 결과 + 오디오)를 입력으로 받아 직원 매칭.
"""
from __future__ import annotations

import base64
import io
import json
import os
import time
from typing import Any
from urllib.parse import urljoin

import numpy as np
import pandas as pd
import plotly.express as px
import plotly.graph_objects as go
import requests
import streamlit as st
from pydub import AudioSegment


# ==========================================
# 기본 설정
# ==========================================
DEFAULT_STT_BASE = os.getenv("STT_API_BASE", "http://localhost:5002")
DEFAULT_SR_BASE = os.getenv("SPEECH_API_BASE", "http://localhost:6003")
EMPLOYEE_DIR = "/home/pps-nipa/jenkins/dev/speech_recognize/src/resoursces/employee"
EXAMPLE_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "example_data")
AUDIO_EXTS = {".wav", ".mp3", ".m4a", ".flac", ".ogg", ".aac", ".webm"}
MIME_MAP = {
    ".wav": "audio/wav", ".mp3": "audio/mpeg", ".m4a": "audio/mp4",
    ".flac": "audio/flac", ".ogg": "audio/ogg", ".aac": "audio/aac",
    ".webm": "audio/webm",
}

POLL_INTERVAL = 2.0           # 초
POLL_TIMEOUT = 60 * 30        # 30분
REQUEST_TIMEOUT = 600

# 실제로 작동 중인 컨테이너:
#   - stt                  : -p 5002:5002 (Whisper)
#   - speech_recognize_dev : -p 6003:5003 (ERes2Net, 모델 마운트)
STT_PRESETS = {
    "local stt (:5002)": "http://localhost:5002",
    "external niq.kro.kr (:5002)": "http://niq.kro.kr:5002",
}
SR_PRESETS = {
    "local speech_recognize_dev (:6003)": "http://localhost:6003",
    "external niq.kro.kr (:6003)": "http://niq.kro.kr:6003",
}


# ==========================================
# API 헬퍼
# ==========================================
def _get_json(url: str, timeout: int = 10) -> tuple[bool, Any]:
    try:
        r = requests.get(url, timeout=timeout)
        r.raise_for_status()
        return True, r.json()
    except requests.RequestException as e:
        return False, str(e)


def stt_health(base: str) -> tuple[bool, Any]:
    return _get_json(urljoin(base + "/", "health"))


def sr_health(base: str) -> tuple[bool, Any]:
    return _get_json(urljoin(base + "/", "health"))


def stt_submit(
    base: str,
    filename: str,
    content: bytes,
    *,
    language: str = "ko",
    align: bool = True,
    diarize: bool = True,
    min_speakers: int | None = None,
    max_speakers: int | None = None,
    batch_size: int = 16,
    beam_size: int = 5,
) -> str:
    files = {"file": (filename, content, "application/octet-stream")}
    data: dict[str, Any] = {
        "language": language,
        "align": str(align).lower(),
        "diarize": str(diarize).lower(),
        "batch_size": int(batch_size),
        "beam_size": int(beam_size),
    }
    if min_speakers is not None:
        data["min_speakers"] = int(min_speakers)
    if max_speakers is not None:
        data["max_speakers"] = int(max_speakers)
    r = requests.post(urljoin(base + "/", "transcribe"), files=files, data=data, timeout=REQUEST_TIMEOUT)
    r.raise_for_status()
    return r.json()["job_id"]


def stt_poll(base: str, job_id: str, progress_cb=None) -> dict[str, Any]:
    return _generic_poll(urljoin(base + "/", f"jobs/{job_id}"), progress_cb)


def sr_submit(
    base: str,
    audio_filename: str,
    audio_bytes: bytes,
    whisper_json_obj: dict[str, Any],
    *,
    threshold: float = 0.2,
) -> str:
    files = {
        "audio": (audio_filename, audio_bytes, "application/octet-stream"),
        "whisper_json": (
            "whisper.json",
            json.dumps(whisper_json_obj, ensure_ascii=False).encode("utf-8"),
            "application/json",
        ),
    }
    data = {"threshold": str(threshold)}
    r = requests.post(urljoin(base + "/", "v1/recognize"), files=files, data=data, timeout=REQUEST_TIMEOUT)
    r.raise_for_status()
    return r.json()["job_id"]


def sr_poll(base: str, job_id: str, progress_cb=None) -> dict[str, Any]:
    return _generic_poll(urljoin(base + "/", f"v1/jobs/{job_id}"), progress_cb)


def _generic_poll(url: str, progress_cb=None) -> dict[str, Any]:
    started = time.time()
    last_status = None
    while True:
        if time.time() - started > POLL_TIMEOUT:
            raise TimeoutError(f"Job polling timeout: {url}")
        r = requests.get(url, timeout=30)
        r.raise_for_status()
        info = r.json()
        status = info.get("status", "unknown")
        if status != last_status and progress_cb:
            progress_cb(info)
            last_status = status
        elif progress_cb and info.get("progress") is not None:
            progress_cb(info)

        if status in ("completed", "failed", "cancelled", "error"):
            return info
        time.sleep(POLL_INTERVAL)


def normalize_progress(info: dict[str, Any]) -> tuple[int, str]:
    """STT(dict {step, percent})와 SR(float 0~100) progress를 동일 형식으로 정규화."""
    raw = info.get("progress")
    status = info.get("status", "...")
    if isinstance(raw, dict):
        pct = int(raw.get("percent") or 0)
        step = raw.get("step") or status
    elif isinstance(raw, (int, float)):
        pct = int(raw)
        step = status
    else:
        pct = 0
        step = status
    return max(0, min(100, pct)), str(step)


SPEAKER_PALETTE = [
    "#4C9AFF", "#FF6B6B", "#36B37E", "#FFAB00", "#9F7AEA",
    "#00B8D9", "#F783AC", "#26C6DA", "#FF7849", "#7E57C2",
]

# 화자 식별이 안 된 / 미등록 직원으로 분류된 라벨들.
# 비교는 소문자, strip 후 수행한다.
UNKNOWN_LABELS = {"", "-", "unknown", "none", "null", "no_match", "no-match", "unmatched"}


def is_unknown_label(label: Any) -> bool:
    """matched_speaker 가 '미상' 류인지."""
    if label is None:
        return True
    try:
        if isinstance(label, float) and pd.isna(label):
            return True
    except Exception:
        pass
    return str(label).strip().lower() in UNKNOWN_LABELS


def merge_consecutive_segments(
    segments: list[dict[str, Any]],
    speaker_field: str,
    gap_tol: float = 0.6,
) -> list[dict[str, Any]]:
    """같은 화자의 인접 segment 를 하나로 합친다.
    (gap_tol 초 이하의 짧은 침묵은 같은 발화로 묶음)
    """
    if not segments:
        return []
    sorted_segs = sorted(segments, key=lambda s: float(s.get("start", 0.0)))
    merged: list[dict[str, Any]] = []
    cur = dict(sorted_segs[0])
    cur["start"] = float(cur.get("start", 0.0))
    cur["end"] = float(cur.get("end", 0.0))
    for s in sorted_segs[1:]:
        st_ = float(s.get("start", 0.0))
        en_ = float(s.get("end", 0.0))
        same_spk = str(s.get(speaker_field, "")) == str(cur.get(speaker_field, ""))
        if same_spk and st_ - cur["end"] <= gap_tol:
            cur["end"] = max(cur["end"], en_)
        else:
            merged.append(cur)
            cur = dict(s)
            cur["start"] = st_
            cur["end"] = en_
    merged.append(cur)
    return merged


def speaker_color(label: str, order: list[str] | None = None) -> str:
    """화자 라벨에 안정적으로 색을 할당."""
    if order is not None and label in order:
        return SPEAKER_PALETTE[order.index(label) % len(SPEAKER_PALETTE)]
    return SPEAKER_PALETTE[abs(hash(label)) % len(SPEAKER_PALETTE)]


# ==========================================
# 오디오 디코딩 / 파형
# ==========================================
@st.cache_data(show_spinner=False, max_entries=8)
def decode_audio(audio_bytes: bytes, _hint_ext: str = "") -> tuple[np.ndarray, int, float]:
    """
    pydub(ffmpeg backend) 로 오디오를 디코드해 모노 float32 array 반환.
    Returns (samples, sample_rate, duration_sec).
    """
    fmt = _hint_ext.lstrip(".").lower() or None
    seg = AudioSegment.from_file(io.BytesIO(audio_bytes), format=fmt)
    arr = np.array(seg.get_array_of_samples())
    if seg.channels and seg.channels > 1:
        arr = arr.reshape(-1, seg.channels).mean(axis=1)
    if seg.sample_width:
        max_val = float(1 << (8 * seg.sample_width - 1))
        arr = arr.astype(np.float32) / max_val
    else:
        arr = arr.astype(np.float32)
    return arr, int(seg.frame_rate), float(len(seg) / 1000.0)


def downsample_envelope(samples: np.ndarray, target_points: int = 2400) -> np.ndarray:
    """피크 엔벨로프로 다운샘플. 긴 오디오도 빠르게 그릴 수 있게."""
    n = len(samples)
    if n == 0:
        return np.array([])
    if n <= target_points:
        return np.abs(samples)
    step = max(1, n // target_points)
    trimmed = samples[: step * (n // step)]
    return np.max(np.abs(trimmed.reshape(-1, step)), axis=1)


def render_waveform(
    audio_bytes: bytes,
    ext_hint: str = "",
    segments: list[dict[str, Any]] | None = None,
    speaker_field: str = "speaker",
    height: int = 220,
    title: str | None = None,
    hide_unknown: bool = False,
    min_label_sec: float = 1.8,
    merge_gap: float = 0.6,
) -> None:
    """
    오디오 파형을 plotly 로 렌더링. segments 가 주어지면 각 발화 구간을
    화자별 색으로 배경에 음영 처리하고, 화자 이름을 라벨로 표시한다.

    - 같은 화자의 인접 segment 는 merge_gap 초 이하 침묵까지 하나로 합쳐
      구간을 더 길게 만들어 라벨 겹침을 줄인다.
    - min_label_sec 초 미만 구간은 라벨 텍스트를 생략(음영만 표시).
    - hide_unknown=True 면 unknown 류 라벨은 음영도 라벨도 생략.
    - 화자 라벨은 위/아래로 교대 배치하여 겹침을 더 줄인다.
    """
    try:
        samples, sr, duration = decode_audio(audio_bytes, ext_hint)
    except Exception as e:
        st.warning(f"파형 디코드 실패: {e}")
        return

    peak = downsample_envelope(samples, target_points=2400)
    if peak.size == 0:
        st.info("오디오 데이터가 비어 있습니다.")
        return

    t = np.linspace(0, duration, num=peak.size)

    fig = go.Figure()
    fig.add_trace(
        go.Scatter(
            x=t, y=peak, mode="lines", line=dict(color="#4C9AFF", width=1),
            fill="tozeroy", fillcolor="rgba(76,154,255,0.25)",
            name="amplitude", hovertemplate="t=%{x:.2f}s<br>|amp|=%{y:.3f}<extra></extra>",
        )
    )
    fig.add_trace(
        go.Scatter(
            x=t, y=-peak, mode="lines", line=dict(color="#4C9AFF", width=1),
            fill="tozeroy", fillcolor="rgba(76,154,255,0.25)",
            showlegend=False, hoverinfo="skip",
        )
    )

    if segments:
        clean: list[dict[str, Any]] = []
        for s in segments:
            try:
                x0 = float(s.get("start", 0.0))
                x1 = float(s.get("end", 0.0))
            except (TypeError, ValueError):
                continue
            if x1 <= x0:
                continue
            label = s.get(speaker_field, "-")
            if hide_unknown and is_unknown_label(label):
                continue
            d = dict(s)
            d["start"] = x0
            d["end"] = x1
            d[speaker_field] = str(label)
            clean.append(d)

        merged = merge_consecutive_segments(clean, speaker_field, gap_tol=merge_gap)
        labels = sorted({str(s.get(speaker_field, "-")) for s in merged})

        annotations: list[dict[str, Any]] = []
        for i, s in enumerate(merged):
            x0, x1 = s["start"], s["end"]
            label = str(s.get(speaker_field, "-"))
            color = speaker_color(label, labels)
            fig.add_vrect(
                x0=x0, x1=x1,
                fillcolor=color, opacity=0.18,
                line_width=0, layer="below",
            )
            if (x1 - x0) >= float(min_label_sec):
                y_anchor = 1.0 if (i % 2 == 0) else 0.0
                yshift = 6 if (i % 2 == 0) else -16
                annotations.append(dict(
                    x=(x0 + x1) / 2,
                    xref="x",
                    y=y_anchor,
                    yref="paper",
                    yshift=yshift,
                    text=f"<b>{label}</b>",
                    showarrow=False,
                    font=dict(size=11, color=color),
                    bgcolor="rgba(255,255,255,0.85)",
                    bordercolor=color,
                    borderwidth=1,
                    borderpad=2,
                ))
        if annotations:
            fig.update_layout(annotations=annotations)

    fig.update_layout(
        title=title,
        height=height,
        margin=dict(l=10, r=10, t=(40 if title else 22), b=10),
        xaxis=dict(title="time (s)", rangeslider=dict(visible=True, thickness=0.05)),
        yaxis=dict(title="amplitude", range=[-1.05, 1.05], showgrid=False),
        showlegend=False,
        template="plotly_white",
    )
    st.plotly_chart(fig, use_container_width=True)
    st.caption(
        f"sample_rate={sr} Hz · duration={duration:.2f}s · samples={len(samples):,}"
    )


# ==========================================
# 화자 식별 시각화
# ==========================================
def render_speaker_timeline(
    df: pd.DataFrame,
    speaker_col: str = "matched_speaker",
    score_col: str | None = "score",
    title: str = "발화 타임라인",
    hide_unknown: bool = True,
    merge_gap: float = 0.6,
) -> None:
    """
    각 segment 를 (start, end, speaker) Gantt 형태로 표시.
    - hide_unknown=True 면 미상/미등록 라벨은 표시하지 않음.
    - 같은 화자의 인접 segment 는 merge_gap 초 이하 침묵까지 병합하여
      bar 가 잘게 쪼개지지 않게 한다(이름과 구간 겹침 완화).
    """
    if df.empty:
        st.info("표시할 segment 가 없습니다.")
        return

    work = df.copy()
    work["speaker_label"] = work[speaker_col].astype(str)

    if hide_unknown:
        mask_unknown = work["speaker_label"].apply(is_unknown_label)
        n_dropped = int(mask_unknown.sum())
        work = work[~mask_unknown]
        if n_dropped:
            st.caption(f"미상(unknown) {n_dropped}개 segment 는 타임라인에서 제외했습니다.")

    if work.empty:
        st.info("등록 직원과 매칭된 segment 가 없습니다.")
        return

    work["start_s"] = work["start"].astype(float)
    work["end_s"] = work["end"].astype(float)

    # 동일 화자 인접 segment 병합
    segs_in = work.to_dict("records")
    for s in segs_in:
        s["start"] = s["start_s"]
        s["end"] = s["end_s"]
    merged = merge_consecutive_segments(segs_in, "speaker_label", gap_tol=merge_gap)

    plot_df = pd.DataFrame(merged)
    plot_df["start_s"] = plot_df["start"].astype(float)
    plot_df["end_s"] = plot_df["end"].astype(float)
    plot_df["duration"] = (plot_df["end_s"] - plot_df["start_s"]).clip(lower=0.01)

    speakers = sorted(plot_df["speaker_label"].unique())
    color_map = {sp: speaker_color(sp, speakers) for sp in speakers}

    hover = ["start_s", "end_s", "duration"]
    if score_col and score_col in plot_df.columns:
        hover.append(score_col)

    fig = px.bar(
        plot_df,
        x="duration",
        y="speaker_label",
        base="start_s",
        color="speaker_label",
        color_discrete_map=color_map,
        orientation="h",
        hover_data=hover,
        title=title,
    )
    # 짧은 bar 위에 화자 이름이 겹쳐서 잘리는 걸 방지하기 위해
    # bar 내부에 텍스트를 표시하지 않음(y축 카테고리 라벨로 충분).
    fig.update_traces(text=None, textposition="none")
    fig.update_layout(
        height=max(220, 70 + 44 * len(speakers)),
        margin=dict(l=10, r=10, t=(50 if title else 18), b=10),
        xaxis=dict(title="time (s)"),
        yaxis=dict(
            title="",
            categoryorder="category ascending",
            tickfont=dict(size=12),
            automargin=True,
        ),
        showlegend=False,
        template="plotly_white",
        bargap=0.45,
    )
    st.plotly_chart(fig, use_container_width=True)


def render_speaker_stats(
    df: pd.DataFrame,
    speaker_col: str = "matched_speaker",
    score_col: str = "score",
) -> None:
    """화자별 발화 점유율 + 평균 score + segment-level 유사도 분포."""
    if df.empty:
        return

    work = df.copy()
    work["start_s"] = work["start"].astype(float)
    work["end_s"] = work["end"].astype(float)
    work["duration"] = (work["end_s"] - work["start_s"]).clip(lower=0)
    work["_score_num"] = pd.to_numeric(work.get(score_col), errors="coerce")
    work["speaker_label"] = work[speaker_col].astype(str)

    speakers = sorted(work["speaker_label"].unique())
    color_map = {sp: speaker_color(sp, speakers) for sp in speakers}

    agg = (
        work.groupby("speaker_label")
        .agg(
            발화_시간_초=("duration", "sum"),
            segments=("duration", "size"),
            평균_score=("_score_num", "mean"),
            최고_score=("_score_num", "max"),
        )
        .reset_index()
        .sort_values("발화_시간_초", ascending=False)
    )

    c1, c2 = st.columns(2)
    with c1:
        pie = px.pie(
            agg, values="발화_시간_초", names="speaker_label",
            color="speaker_label", color_discrete_map=color_map,
            hole=0.45, title="화자별 발화 시간 점유율",
        )
        pie.update_traces(textposition="inside", textinfo="percent+label")
        pie.update_layout(
            height=320, margin=dict(l=10, r=10, t=40, b=10),
            template="plotly_white", showlegend=False,
        )
        st.plotly_chart(pie, use_container_width=True)

    with c2:
        bar = px.bar(
            agg, x="speaker_label", y="평균_score",
            color="speaker_label", color_discrete_map=color_map,
            text="평균_score", title="화자별 평균 유사도(score)",
            hover_data=["segments", "최고_score", "발화_시간_초"],
        )
        bar.update_traces(texttemplate="%{text:.3f}", textposition="outside")
        bar.update_layout(
            height=320, margin=dict(l=10, r=10, t=40, b=10),
            template="plotly_white", showlegend=False,
            yaxis=dict(title="cosine similarity", range=[0, 1.05]),
            xaxis=dict(title=""),
        )
        st.plotly_chart(bar, use_container_width=True)

    dist_df = work.dropna(subset=["_score_num"])
    if not dist_df.empty:
        strip = px.strip(
            dist_df, x="speaker_label", y="_score_num",
            color="speaker_label", color_discrete_map=color_map,
            stripmode="overlay", title="발화별 유사도 분포 (segment-level)",
            hover_data=["start_s", "end_s", "text"] if "text" in dist_df.columns else None,
        )
        strip.update_traces(jitter=0.35, marker=dict(size=10, opacity=0.7))
        strip.update_layout(
            height=300, margin=dict(l=10, r=10, t=40, b=10),
            template="plotly_white", showlegend=False,
            xaxis=dict(title=""),
            yaxis=dict(title="cosine similarity", range=[0, 1.05]),
        )
        st.plotly_chart(strip, use_container_width=True)

    st.markdown("##### 직원별 요약")
    st.dataframe(
        agg.rename(columns={"speaker_label": "직원/라벨"}),
        hide_index=True,
        use_container_width=True,
    )


# ==========================================
# 다운로드 (st.download_button 우회: HTML data-uri 링크)
# ==========================================
def download_link(
    data: bytes | str,
    filename: str,
    label: str,
    mime: str = "application/octet-stream",
) -> None:
    """
    st.download_button 은 일부 streamlit 버전 + 외부 도메인 환경에서
    "Failed to fetch dynamically imported module ... DownloadButton...js" 가 발생한다.
    동일 기능을 base64 data-URI HTML 링크로 제공해 청크 의존을 제거한다.
    """
    if isinstance(data, str):
        data = data.encode("utf-8")
    b64 = base64.b64encode(data).decode("ascii")
    href = f"data:{mime};base64,{b64}"
    st.markdown(
        f'''
        <a href="{href}" download="{filename}"
           style="display:inline-block;padding:0.45rem 0.9rem;border-radius:0.5rem;
                  background:#0E1117;color:#FAFAFA;text-decoration:none;
                  border:1px solid #4C9AFF;font-size:0.9rem;">
          {label}
        </a>
        ''',
        unsafe_allow_html=True,
    )


# ==========================================
# 결과 정규화 / 표시
# ==========================================
def extract_segments(stt_result: dict[str, Any]) -> list[dict[str, Any]]:
    """STT 응답에서 segments 리스트만 뽑아낸다."""
    if not stt_result:
        return []
    result = stt_result.get("result") or {}
    segs = result.get("segments") or stt_result.get("segments") or []
    return segs


def segments_to_df(segments: list[dict[str, Any]]) -> pd.DataFrame:
    rows = []
    for s in segments:
        rows.append(
            {
                "start": round(float(s.get("start", 0.0)), 2),
                "end": round(float(s.get("end", 0.0)), 2),
                "duration": round(float(s.get("end", 0.0)) - float(s.get("start", 0.0)), 2),
                "speaker": s.get("speaker", "-"),
                "text": (s.get("text") or "").strip(),
            }
        )
    return pd.DataFrame(rows)


def sr_results_to_df(sr_result: dict[str, Any]) -> pd.DataFrame:
    """speech_recognize 응답에서 results 추출."""
    if not sr_result:
        return pd.DataFrame()
    inner = sr_result.get("result") or sr_result
    items = inner.get("results") or inner.get("segments") or []

    rows = []
    for r in items:
        speaker = r.get("speaker") or r.get("matched_name") or r.get("employee") or "-"
        score = r.get("score") or r.get("similarity") or r.get("confidence")
        rows.append(
            {
                "start": round(float(r.get("start", 0.0)), 2),
                "end": round(float(r.get("end", 0.0)), 2),
                "matched_speaker": speaker,
                "score": round(float(score), 3) if isinstance(score, (int, float)) else "-",
                "text": (r.get("text") or "").strip(),
            }
        )
    return pd.DataFrame(rows)


def list_examples() -> list[str]:
    if not os.path.isdir(EXAMPLE_DIR):
        return []
    return sorted(
        f for f in os.listdir(EXAMPLE_DIR)
        if os.path.isfile(os.path.join(EXAMPLE_DIR, f))
        and os.path.splitext(f)[1].lower() in AUDIO_EXTS
        and not f.startswith(".")
    )


def load_example(filename: str) -> tuple[str, bytes, str]:
    path = os.path.join(EXAMPLE_DIR, filename)
    with open(path, "rb") as f:
        data = f.read()
    ext = os.path.splitext(filename)[1].lower()
    return filename, data, MIME_MAP.get(ext, "application/octet-stream")


def list_employees() -> list[str]:
    if not os.path.isdir(EMPLOYEE_DIR):
        return []
    return sorted(
        d for d in os.listdir(EMPLOYEE_DIR)
        if os.path.isdir(os.path.join(EMPLOYEE_DIR, d)) and not d.startswith(".")
    )


def employee_summary() -> pd.DataFrame:
    rows = []
    if not os.path.isdir(EMPLOYEE_DIR):
        return pd.DataFrame()
    for name in list_employees():
        files = [
            f for f in os.listdir(os.path.join(EMPLOYEE_DIR, name))
            if f.lower().endswith((".wav", ".mp3", ".m4a", ".flac"))
        ]
        rows.append({"이름": name, "샘플 파일 수": len(files)})
    return pd.DataFrame(rows)


# ==========================================
# 앱
# ==========================================
def main() -> None:
    st.set_page_config(page_title="STT + Speaker ID Demo", page_icon="🎙️", layout="wide")
    st.title("🎙️ STT + 화자 식별 데모")
    st.caption(
        "Whisper로 음성을 텍스트화하고, ERes2Net으로 각 발화 구간을 사내 직원과 매칭합니다. "
        "두 단계를 각각 따로 실행해볼 수 있습니다."
    )

    # ---------- Sidebar ----------
    with st.sidebar:
        st.header("⚙️ 서버 설정")

        st.markdown("**STT (Whisper)**")
        stt_preset = st.selectbox(
            "STT 프리셋",
            list(STT_PRESETS.keys()),
            index=0,
            label_visibility="collapsed",
        )
        stt_base = st.text_input(
            "STT Base URL", value=STT_PRESETS[stt_preset], key="stt_base"
        ).rstrip("/")

        st.markdown("**Speech Recognize (직원 매칭)**")
        sr_preset = st.selectbox(
            "SR 프리셋",
            list(SR_PRESETS.keys()),
            index=0,
            label_visibility="collapsed",
        )
        sr_base = st.text_input(
            "Speech Recognize Base URL", value=SR_PRESETS[sr_preset], key="sr_base"
        ).rstrip("/")

        if st.button("두 서버 헬스 체크", use_container_width=True):
            c1, c2 = st.columns(2)
            with c1:
                ok, info = stt_health(stt_base)
                st.markdown("**STT**")
                st.success("OK") if ok else st.error("DOWN")
                st.json(info if ok else {"error": info})
            with c2:
                ok, info = sr_health(sr_base)
                st.markdown("**Speech Recognize**")
                st.success("OK") if ok else st.error("DOWN")
                st.json(info if ok else {"error": info})

        st.divider()
        st.subheader("등록된 직원")
        emp_df = employee_summary()
        if emp_df.empty:
            st.warning(f"디렉토리를 찾을 수 없습니다.\n`{EMPLOYEE_DIR}`")
        else:
            st.dataframe(emp_df, hide_index=True, use_container_width=True)
            st.caption(f"총 {len(emp_df)}명 / 경로 `{EMPLOYEE_DIR}`")

    # ---------- 공통 오디오 소스 ----------
    st.subheader("🎵 분석할 오디오")
    examples = list_examples()

    src_options = ["직접 업로드"]
    if examples:
        src_options.append(f"예시 파일에서 선택 ({len(examples)}개)")
    src_mode = st.radio(
        "소스",
        src_options,
        horizontal=True,
        label_visibility="collapsed",
    )

    audio_name: str | None = None
    audio_bytes: bytes | None = None
    audio_mime: str = "audio/wav"

    if src_mode == "직접 업로드":
        uploaded = st.file_uploader(
            "WAV/MP3/M4A/FLAC/OGG (회의 녹음 등)",
            type=["wav", "mp3", "m4a", "flac", "ogg", "aac", "webm"],
            accept_multiple_files=False,
        )
        if uploaded is not None:
            audio_name = uploaded.name
            audio_bytes = uploaded.getvalue()
            audio_mime = uploaded.type or "audio/wav"
    else:
        picked = st.selectbox("예시 파일", examples, index=0)
        st.caption(f"📁 `{EXAMPLE_DIR}/{picked}`")
        try:
            audio_name, audio_bytes, audio_mime = load_example(picked)
        except OSError as e:
            st.error(f"예시 파일을 불러오지 못했습니다: {e}")

    if audio_bytes is not None:
        size_mb = len(audio_bytes) / (1024 * 1024)
        st.caption(f"🎧 `{audio_name}` · {size_mb:.2f} MB · `{audio_mime}`")
        st.audio(audio_bytes, format=audio_mime)
        with st.expander("🌊 파형 미리보기", expanded=True):
            ext_hint = os.path.splitext(audio_name or "")[1]
            render_waveform(audio_bytes, ext_hint=ext_hint, height=200)

    # ---------- 탭 ----------
    tab_stt, tab_sr, tab_raw = st.tabs(
        ["1️⃣ STT (Whisper)", "2️⃣ 화자 식별 (직원 매칭)", "🧾 Raw JSON"]
    )

    # ===== 1) STT =====
    with tab_stt:
        st.markdown(
            "음성을 텍스트로 변환합니다. 화자 분리(diarization)가 활성된 모델이라면 "
            "`SPEAKER_00`, `SPEAKER_01` 같은 라벨이 함께 표시됩니다."
        )
        col_opt1, col_opt2, col_opt3, col_opt4, col_opt5, col_opt6 = st.columns(6)
        language = col_opt1.selectbox("언어", ["ko", "en", "ja", "zh"], index=0)
        diarize = col_opt2.checkbox(
            "화자 분리(diarize)", value=True,
            help="STT 컨테이너의 pyannote 모델이 로드되어 있어야 작동",
        )
        batch = col_opt3.number_input(
            "batch_size", min_value=1, max_value=64, value=16,
            help="WhisperX 기본 16. OOM 발생 시 4~8로 낮추기.",
        )
        beam = col_opt4.number_input(
            "beam_size", min_value=1, max_value=20, value=5,
            help="빔 탐색 폭. WhisperX 기본 5.",
        )
        min_sp = col_opt5.number_input("min_speakers", min_value=0, max_value=20, value=0)
        max_sp = col_opt6.number_input("max_speakers", min_value=0, max_value=20, value=0)

        run_stt = st.button(
            "🚀 STT 실행", type="primary",
            disabled=audio_bytes is None, key="run_stt",
        )
        if run_stt and audio_bytes is not None and audio_name is not None:
            try:
                with st.spinner("STT 요청 제출 중..."):
                    job_id = stt_submit(
                        stt_base,
                        audio_name,
                        audio_bytes,
                        language=language,
                        align=True,
                        diarize=diarize,
                        min_speakers=min_sp or None,
                        max_speakers=max_sp or None,
                        batch_size=int(batch),
                        beam_size=int(beam),
                    )

                status_box = st.empty()
                progress_bar = st.progress(0, text=f"job_id={job_id}")

                def cb(info: dict[str, Any]) -> None:
                    pct, step = normalize_progress(info)
                    progress_bar.progress(pct, text=f"[{info.get('status')}] {step}")
                    status_box.caption(f"job_id={job_id} · status={info.get('status')} · {pct}%")

                result = stt_poll(stt_base, job_id, progress_cb=cb)
                progress_bar.empty()
                status_box.empty()

                if result.get("status") != "completed":
                    st.error(f"STT 실패: {result.get('status')}")
                    st.json(result)
                else:
                    st.session_state["stt_result"] = result
                    st.session_state["stt_audio_name"] = audio_name
                    st.session_state["stt_audio_bytes"] = audio_bytes
                    st.success(
                        f"완료 · {result.get('result', {}).get('processing_time', 0):.2f}초 · "
                        f"segments {len(extract_segments(result))}개"
                    )
            except requests.HTTPError as e:
                st.error(f"HTTP {e.response.status_code}: {e.response.text}")
            except requests.RequestException as e:
                st.error(f"요청 실패: {e}")
            except TimeoutError as e:
                st.error(str(e))

        stt_result = st.session_state.get("stt_result")
        if stt_result:
            segs = extract_segments(stt_result)
            df = segments_to_df(segs)

            stt_audio_bytes = st.session_state.get("stt_audio_bytes")
            stt_audio_name = st.session_state.get("stt_audio_name") or ""
            if stt_audio_bytes and segs:
                st.markdown("### 🌊 화자별 발화 구간 (파형 오버레이)")
                render_waveform(
                    stt_audio_bytes,
                    ext_hint=os.path.splitext(stt_audio_name)[1],
                    segments=segs,
                    speaker_field="speaker",
                    height=260,
                )

            st.markdown(f"### 📋 STT 결과 — {len(df)} segments")
            if not df.empty:
                speakers = sorted(df["speaker"].astype(str).unique())
                st.caption("감지된 화자 라벨: " + ", ".join(f"`{s}`" for s in speakers))
            st.dataframe(df, hide_index=True, use_container_width=True)

            st.markdown("### 📝 합본 텍스트")
            joined = "\n".join(
                f"[{r['start']:.2f}–{r['end']:.2f}] ({r['speaker']}) {r['text']}"
                for _, r in df.iterrows()
            )
            st.text_area("transcript", joined, height=300, label_visibility="collapsed")

            download_link(
                json.dumps(stt_result, ensure_ascii=False, indent=2),
                filename="stt_result.json",
                label="📥 STT JSON 다운로드",
                mime="application/json",
            )
        else:
            st.info("오디오 업로드 후 **STT 실행** 버튼을 눌러주세요.")

    # ===== 2) 화자 식별 =====
    with tab_sr:
        st.markdown(
            "위에서 얻은 STT 결과(segments)와 같은 오디오를 보내, "
            "각 발화 구간이 **사내 등록 직원** 중 누구의 목소리인지 식별합니다."
        )
        threshold = st.slider(
            "매칭 임계값 (threshold)",
            min_value=0.0, max_value=1.0, value=0.2, step=0.05,
            help="ERes2Net 코사인 유사도. speech_recognize 기본값 0.2. 낮을수록 관대, 높을수록 엄격.",
        )

        stt_result = st.session_state.get("stt_result")
        ready = stt_result is not None and (
            audio_bytes is not None or st.session_state.get("stt_audio_bytes") is not None
        )

        if not stt_result:
            st.info("먼저 **1) STT 탭**에서 STT를 실행해주세요.")
        elif audio_bytes is None and not st.session_state.get("stt_audio_bytes"):
            st.info("오디오 파일을 다시 선택해주세요. (탭 1 결과는 보존됩니다)")

        run_sr = st.button(
            "🚀 화자 식별 실행 (STT 결과 사용)",
            type="primary",
            disabled=not ready,
            key="run_sr",
        )
        if run_sr and ready and stt_result is not None:
            audio_name_eff = st.session_state.get("stt_audio_name") or audio_name
            audio_bytes_eff = st.session_state.get("stt_audio_bytes") or audio_bytes
            try:
                with st.spinner("화자 식별 요청 제출 중..."):
                    job_id = sr_submit(
                        sr_base, audio_name_eff, audio_bytes_eff,
                        stt_result, threshold=threshold,
                    )

                status_box = st.empty()
                progress_bar = st.progress(0, text=f"job_id={job_id}")

                def cb(info: dict[str, Any]) -> None:
                    pct, step = normalize_progress(info)
                    progress_bar.progress(pct, text=f"[{info.get('status')}] {step}")
                    status_box.caption(f"job_id={job_id} · status={info.get('status')} · {pct}%")

                result = sr_poll(sr_base, job_id, progress_cb=cb)
                progress_bar.empty()
                status_box.empty()

                if result.get("status") != "completed":
                    st.error(f"화자 식별 실패: {result.get('status')}")
                    st.json(result)
                else:
                    st.session_state["sr_result"] = result
                    st.success("화자 식별 완료")
            except requests.HTTPError as e:
                st.error(f"HTTP {e.response.status_code}: {e.response.text}")
            except requests.RequestException as e:
                st.error(f"요청 실패: {e}")
            except TimeoutError as e:
                st.error(str(e))

        sr_result = st.session_state.get("sr_result")
        if sr_result:
            df_sr = sr_results_to_df(sr_result)

            # STT 라벨 + 매칭된 이름 비교 뷰
            stt_df = segments_to_df(extract_segments(st.session_state.get("stt_result", {}) or {}))
            if not stt_df.empty and not df_sr.empty and len(stt_df) == len(df_sr):
                merged = stt_df[["start", "end", "speaker", "text"]].copy()
                merged.rename(columns={"speaker": "stt_speaker"}, inplace=True)
                merged["matched_speaker"] = df_sr["matched_speaker"].values
                merged["score"] = df_sr["score"].values
                merged = merged[["start", "end", "stt_speaker", "matched_speaker", "score", "text"]]
                table_df = merged
            else:
                table_df = df_sr

            # 핵심 지표
            if not df_sr.empty:
                matched = sorted(df_sr["matched_speaker"].astype(str).unique())
                score_series = pd.to_numeric(df_sr["score"], errors="coerce")
                mc1, mc2, mc3 = st.columns(3)
                mc1.metric("매칭된 인물 수", f"{len(matched)} 명")
                mc2.metric("Segment 수", f"{len(df_sr)}")
                mc3.metric(
                    "평균 유사도",
                    f"{score_series.mean():.3f}" if score_series.notna().any() else "-",
                )
                st.caption("매칭된 인물: " + ", ".join(f"**{m}**" for m in matched))

            # 파형 오버레이 (화자 색 = 매칭된 직원)
            sr_audio_bytes = st.session_state.get("stt_audio_bytes")
            sr_audio_name = st.session_state.get("stt_audio_name") or ""
            if sr_audio_bytes and not table_df.empty:
                st.markdown("### 🌊 매칭된 화자 오버레이")
                segs_for_wave = [
                    {
                        "start": r["start"],
                        "end": r["end"],
                        "speaker": r.get("matched_speaker", "-"),
                    }
                    for _, r in table_df.iterrows()
                ]
                render_waveform(
                    sr_audio_bytes,
                    ext_hint=os.path.splitext(sr_audio_name)[1],
                    segments=segs_for_wave,
                    speaker_field="speaker",
                    height=280,
                    hide_unknown=True,
                )

            # 타임라인
            if not table_df.empty:
                st.markdown("### 🕓 발화 타임라인 (직원별)")
                render_speaker_timeline(
                    table_df,
                    speaker_col="matched_speaker",
                    score_col="score",
                    title=None,
                )

            # 화자 통계
            if not table_df.empty:
                st.markdown("### 📊 화자별 통계 & 목소리 패턴 일치도")
                render_speaker_stats(
                    table_df, speaker_col="matched_speaker", score_col="score",
                )

            st.markdown(f"### 👤 매칭 결과 표 — {len(table_df)} segments")
            st.dataframe(table_df, hide_index=True, use_container_width=True)

            download_link(
                json.dumps(sr_result, ensure_ascii=False, indent=2),
                filename="speaker_recognition_result.json",
                label="📥 화자 식별 JSON 다운로드",
                mime="application/json",
            )
        elif stt_result:
            st.caption("아직 화자 식별을 실행하지 않았습니다.")

    # ===== 3) Raw JSON =====
    with tab_raw:
        c1, c2 = st.columns(2)
        with c1:
            st.markdown("**STT raw**")
            st.json(st.session_state.get("stt_result") or {"message": "no data"})
        with c2:
            st.markdown("**Speech Recognize raw**")
            st.json(st.session_state.get("sr_result") or {"message": "no data"})


if __name__ == "__main__":
    main()
