# -*- coding: utf-8 -*-
"""App Store スクリーンショット（1242x2688）の artboard を組み立てる。

画面の中身は MichiNavi の実装（Phone/ContentView.swift, Phone/TrackSheet.swift,
CarPlay/ManeuverCard.swift, Core/DriveBrief.swift）から値を写している。
端末画面は 414x896pt を scale(2.4) で 994x2151px に引き伸ばして描く。
"""
import json, os, pathlib

OUT = pathlib.Path(__file__).parent
W, H = 1242, 2688

# ── アプリから写した色 ───────────────────────────────────────────
SIGN_BLUE = "#0067C0"      # ManeuverCard.ordinaryColor（JIS 安全色の青）
SIGN_GREEN = "#006B3C"     # ManeuverCard.highwayColor
SYS_BLUE = "#007AFF"       # SwiftUI .blue（経路の線・iPhone の案内バナー）
PINK = "#FF2D55"           # SwiftUI .pink（初めての道・収穫）
TRAVELLED = "#737373"      # Color(white: 0.45)
TRACK = "#D93399"          # TrackStore の線（red .85 / green .2 / blue .6）
MESH = "rgba(255,45,85,0.16)"
ORANGE = "#FF9500"
PURPLE = "#AF52DE"
RED = "#FF3B30"
LABEL2 = "#6C6C70"         # .secondary 相当
LABEL3 = "#A0A0A6"         # .tertiary 相当
MATERIAL = "rgba(249,249,251,0.88)"   # .regularMaterial の代わり
SEP = "rgba(60,60,67,0.14)"

JP = '"Hiragino Sans","Hiragino Kaku Gothic ProN",-apple-system,BlinkMacSystemFont,"Helvetica Neue",sans-serif'

# ── SF Symbols を手描きした差し替え ─────────────────────────────
def icon(name, size=20, color="currentColor", stroke=1.8):
    s = f'width="{size}" height="{size}" viewBox="0 0 24 24" fill="none" style="flex:none;display:block"'
    st = f'stroke="{color}" stroke-width="{stroke}" stroke-linecap="round" stroke-linejoin="round"'
    if name == "magnifyingglass":
        b = f'<circle cx="10.5" cy="10.5" r="6.6" {st}/><path d="M15.4 15.4 L20.5 20.5" {st}/>'
    elif name == "house.fill":
        b = f'<path d="M2.6 11.4 L12 3.4 L21.4 11.4 V20 a1.4 1.4 0 0 1-1.4 1.4 H4 A1.4 1.4 0 0 1 2.6 20 Z" fill="{color}"/>'
    elif name == "bag.fill":
        b = (f'<path d="M3.2 8.6 h17.6 v10.6 a1.6 1.6 0 0 1-1.6 1.6 H4.8 A1.6 1.6 0 0 1 3.2 19.2 Z" fill="{color}"/>'
             f'<path d="M8.6 8.4 V6.6 A3.4 3.4 0 0 1 12 3.2 a3.4 3.4 0 0 1 3.4 3.4 V8.4" {st} fill="none"/>')
    elif name == "ellipsis.circle":
        b = (f'<circle cx="12" cy="12" r="9.2" {st}/>'
             f'<circle cx="7.9" cy="12" r="1.25" fill="{color}"/><circle cx="12" cy="12" r="1.25" fill="{color}"/>'
             f'<circle cx="16.1" cy="12" r="1.25" fill="{color}"/>')
    elif name == "arrow.turn.up.right":
        b = (f'<path d="M4.6 20.8 V11.6 a4.6 4.6 0 0 1 4.6-4.6 H18.4" {st}/>'
             f'<path d="M14.6 3 L19.2 7 L14.6 11" {st}/>')
    elif name == "sparkles":
        b = (f'<path d="M9.4 2.8 L10.9 7 L15 8.5 L10.9 10 L9.4 14.2 L7.9 10 L3.8 8.5 L7.9 7 Z" fill="{color}"/>'
             f'<path d="M17.2 12.6 L18.1 15 L20.5 15.9 L18.1 16.8 L17.2 19.2 L16.3 16.8 L13.9 15.9 L16.3 15 Z" fill="{color}"/>'
             f'<path d="M5.4 16.6 L6 18.3 L7.7 18.9 L6 19.5 L5.4 21.2 L4.8 19.5 L3.1 18.9 L4.8 18.3 Z" fill="{color}"/>')
    elif name == "car.side.fill":
        b = (f'<path d="M2.4 16.4 v-2.6 a2 2 0 0 1 1.3-1.9 l2.1-0.7 2.6-2.9 a3 3 0 0 1 2.2-1 h3.2 a3 3 0 0 1 2.3 1.1 l2.3 2.8 2 0.6 a2 2 0 0 1 1.4 1.9 v2.7 a1.1 1.1 0 0 1-1.1 1.1 H3.5 a1.1 1.1 0 0 1-1.1-1.1 Z" fill="{color}"/>'
             f'<circle cx="7" cy="17.4" r="2.3" fill="{color}"/><circle cx="17" cy="17.4" r="2.3" fill="{color}"/>'
             f'<circle cx="7" cy="17.4" r="0.9" fill="#fff"/><circle cx="17" cy="17.4" r="0.9" fill="#fff"/>')
    elif name == "exclamationmark.triangle.fill":
        b = (f'<path d="M12 3.2 L22.4 20.4 H1.6 Z" fill="{color}"/>'
             f'<path d="M12 9.2 V14.6" stroke="#fff" stroke-width="2" stroke-linecap="round"/>'
             f'<circle cx="12" cy="17.6" r="1.15" fill="#fff"/>')
    elif name == "arrow.triangle.branch":
        b = (f'<path d="M6 20.5 V7.5" {st}/><path d="M6 11.4 c0-2.6 2-3.9 5.4-3.9 H18" {st}/>'
             f'<path d="M14.6 4.3 L18 7.5 L14.6 10.7" {st}/><circle cx="6" cy="20.5" r="1.7" fill="{color}"/>')
    elif name == "mappin.and.ellipse":
        b = (f'<path d="M12 2.6 a5.2 5.2 0 0 1 5.2 5.2 c0 3.7-5.2 9.4-5.2 9.4 S6.8 11.5 6.8 7.8 A5.2 5.2 0 0 1 12 2.6 Z" fill="{color}"/>'
             f'<circle cx="12" cy="7.8" r="1.9" fill="#fff"/>'
             f'<ellipse cx="12" cy="19.4" rx="7.4" ry="2.4" {st} stroke-width="1.5"/>')
    elif name == "chevron.right":
        b = f'<path d="M9 4.5 L16.5 12 L9 19.5" {st} stroke-width="2.2"/>'
    elif name == "clock":
        b = f'<circle cx="12" cy="12" r="9.2" {st}/><path d="M12 6.6 V12 l3.6 2.2" {st}/>'
    elif name == "xmark.circle.fill":
        b = (f'<circle cx="12" cy="12" r="9.6" fill="{color}"/>'
             f'<path d="M8.8 8.8 L15.2 15.2 M15.2 8.8 L8.8 15.2" stroke="#fff" stroke-width="2" stroke-linecap="round"/>')
    elif name == "map.fill":
        b = (f'<path d="M2.4 5.8 L8.8 3.2 V18.2 L2.4 20.8 Z" fill="{color}"/>'
             f'<path d="M9.8 3.2 L15.2 5.8 V20.8 L9.8 18.2 Z" fill="{color}" opacity="0.72"/>'
             f'<path d="M16.2 5.8 L21.6 3.2 V18.2 L16.2 20.8 Z" fill="{color}"/>')
    elif name == "building.2.fill":
        b = (f'<path d="M3.2 9.4 h7.2 V21 H3.2 Z" fill="{color}" opacity="0.72"/>'
             f'<path d="M11.4 3.4 h9.4 V21 h-9.4 Z" fill="{color}"/>'
             f'<g fill="#fff"><rect x="13.3" y="6" width="2" height="2" rx="0.4"/><rect x="17" y="6" width="2" height="2" rx="0.4"/>'
             f'<rect x="13.3" y="10" width="2" height="2" rx="0.4"/><rect x="17" y="10" width="2" height="2" rx="0.4"/>'
             f'<rect x="13.3" y="14" width="2" height="2" rx="0.4"/><rect x="17" y="14" width="2" height="2" rx="0.4"/>'
             f'<rect x="5.2" y="12" width="1.8" height="1.8" rx="0.4"/><rect x="8" y="12" width="1.8" height="1.8" rx="0.4"/>'
             f'<rect x="5.2" y="15.6" width="1.8" height="1.8" rx="0.4"/><rect x="8" y="15.6" width="1.8" height="1.8" rx="0.4"/></g>')
    elif name == "flag.checkered":
        b = (f'<path d="M5 21.2 V3.4" {st} stroke-width="2"/>'
             f'<path d="M5 4.4 h14.6 v9.4 H5 Z" fill="{color}" opacity="0.25"/>'
             f'<g fill="{color}"><rect x="5" y="4.4" width="3.65" height="3.13"/><rect x="12.3" y="4.4" width="3.65" height="3.13"/>'
             f'<rect x="8.65" y="7.53" width="3.65" height="3.13"/><rect x="15.95" y="7.53" width="3.65" height="3.13"/>'
             f'<rect x="5" y="10.66" width="3.65" height="3.13"/><rect x="12.3" y="10.66" width="3.65" height="3.13"/></g>')
    elif name == "curvepath":
        b = (f'<path d="M5.4 18.6 C 5.4 12, 9.4 9.6, 12 9.6 c 2.6 0 6.6 2.4 6.6 -4.2" {st} stroke-dasharray="0.1 3.6"/>'
             f'<circle cx="5.4" cy="19.4" r="2.5" fill="{color}"/><circle cx="18.6" cy="4.6" r="2.5" fill="{color}"/>')
    elif name == "location.fill":
        b = f'<path d="M20.8 3.6 L3.6 10.8 a0.6 0.6 0 0 0 0.1 1.1 l6.9 2.2 2.2 6.9 a0.6 0.6 0 0 0 1.1 0.1 Z" fill="{color}"/>'
    elif name == "mic.fill":
        b = (f'<rect x="8.8" y="2.4" width="6.4" height="12" rx="3.2" fill="{color}"/>'
             f'<path d="M5.4 11.6 a6.6 6.6 0 0 0 13.2 0" {st} stroke-width="2"/><path d="M12 18.2 V21.4" {st} stroke-width="2"/>')
    elif name == "speaker.wave.2.fill":
        b = (f'<path d="M3 9.4 h3.4 L11 5.2 v13.6 L6.4 14.6 H3 Z" fill="{color}"/>'
             f'<path d="M14.4 8.8 a4.6 4.6 0 0 1 0 6.4" {st} stroke-width="1.9"/>'
             f'<path d="M17.6 6 a8.4 8.4 0 0 1 0 12" {st} stroke-width="1.9"/>')
    elif name == "xmark":
        b = f'<path d="M5.4 5.4 L18.6 18.6 M18.6 5.4 L5.4 18.6" {st} stroke-width="2.2"/>'
    elif name == "plus":
        b = f'<path d="M12 4.6 V19.4 M4.6 12 H19.4" {st} stroke-width="2.2"/>'
    elif name == "minus":
        b = f'<path d="M4.6 12 H19.4" {st} stroke-width="2.2"/>'
    elif name == "arrow.up.left.and.arrow.down.right":
        b = (f'<path d="M4 10 V4 h6" {st}/><path d="M4 4 L10.4 10.4" {st}/>'
             f'<path d="M20 14 V20 h-6" {st}/><path d="M20 20 L13.6 13.6" {st}/>')
    elif name == "hand.draw":
        b = (f'<path d="M9 12.6 V5.4 a1.7 1.7 0 0 1 3.4 0 V11 m0-1.4 a1.7 1.7 0 0 1 3.4 0 v1.6 m0-1.2 a1.7 1.7 0 0 1 3.4 0 V16 c0 3.2-2.4 5.6-5.6 5.6 -3.4 0-4.6-1.6-6.2-4.2 L5 14.4 a1.7 1.7 0 0 1 2.8-1.9 Z" {st}/>')
    elif name == "arrow.triangle.turn.up.right.circle":
        b = f'<circle cx="12" cy="12" r="9.2" {st}/><path d="M8 16.8 v-3.4 a3 3 0 0 1 3-3 h4.4" {st}/><path d="M13.2 7.6 L16.4 10.4 L13.2 13.2" {st}/>'
    else:
        b = ""
    return f'<svg {s}>{b}</svg>'


# ── 地図（デモデータ：東京駅が現在地）────────────────────────────
LAND, BLOCK, CASE, ROAD = "#EFECE6", "#E6E1D8", "#DCD6C9", "#FFFFFF"
GREEN, WATER, HWY, HWYC = "#CFE3C0", "#A8D3EC", "#F4DFA0", "#DFC478"
MAPLBL = "#8C8578"

def _rd(d, w, klass="road"):
    """道路 1 本ぶん（外枠＋白）。"""
    c = CASE if klass == "road" else HWYC
    f = ROAD if klass == "road" else HWY
    return (f'<path d="{d}" fill="none" stroke="{c}" stroke-width="{w+2.6}" stroke-linecap="round"/>'
            f'<path d="{d}" fill="none" stroke="{f}" stroke-width="{w}" stroke-linecap="round"/>')

def map_street(route="", w=414, h=896, vb="0 0 414 896", tracks=""):
    """東京駅周辺の街区スケール。丸の内／八重洲の格子を -9 度傾けて描く。"""
    g = []
    for x in (50, 125, 245, 320, 440):
        g.append(_rd(f"M{x} -180 V1080", 5))
    for y in (105, 295, 380, 470, 645, 735, 825):
        g.append(_rd(f"M-180 {y} H600", 5))
    g.append(_rd("M200 -180 V1080", 11))   # 日比谷通り
    g.append(_rd("M380 -180 V1080", 10))   # 中央通り
    g.append(_rd("M-180 205 H600", 11))    # 永代通り
    g.append(_rd("M-180 560 H600", 10))    # 八重洲通り
    blocks = "".join(
        f'<rect x="{x}" y="{y}" width="{bw}" height="{bh}" rx="2" fill="{BLOCK}"/>'
        for x, y, bw, bh in [(210, 215, 44, 68), (210, 305, 44, 62), (210, 390, 44, 68),
                             (330, 215, 42, 68), (390, 215, 44, 68), (390, 305, 44, 62),
                             (135, 215, 54, 68), (135, 305, 54, 62), (135, 390, 54, 68),
                             (330, 580, 42, 52), (390, 580, 44, 52), (210, 580, 44, 52),
                             (135, 580, 54, 52), (60, 580, 54, 52), (330, 660, 42, 62)])
    jr = (f'<rect x="262" y="-180" width="38" height="1260" fill="#D9D3C5"/>'
          f'<path d="M271 -180 V1080 M281 -180 V1080 M291 -180 V1080" stroke="#C3BBA9" stroke-width="1.6"/>')
    station = (f'<rect x="300" y="350" width="58" height="196" rx="3" fill="#D2CABA" stroke="#BFB6A2" stroke-width="1.4"/>'
               f'<rect x="308" y="366" width="42" height="26" rx="2" fill="#C6BCA8"/>'
               f'<rect x="308" y="500" width="42" height="30" rx="2" fill="#C6BCA8"/>')
    hwy = _rd("M-180 700 C 40 690, 150 640, 240 520 C 320 415, 380 300, 600 250", 9, "hwy")
    return f'''<svg width="{w}" height="{h}" viewBox="{vb}" preserveAspectRatio="xMidYMid slice" style="display:block">
<rect x="-400" y="-400" width="1400" height="1800" fill="{LAND}"/>
<g transform="rotate(-9 207 448)">
<path d="M-180 90 L120 60 L152 300 L118 470 L96 620 L-180 640 Z" fill="{GREEN}"/>
<path d="M120 60 L152 300 L118 470 L96 620" fill="none" stroke="{WATER}" stroke-width="13"/>
<path d="M20 700 h96 v120 h-96 Z" fill="{GREEN}"/>
{blocks}{jr}{"".join(g)}{hwy}{station}
{tracks}{route}
</g>
<text x="34" y="300" font-family={JP!r} font-size="12" font-weight="600" fill="{MAPLBL}">皇居</text>
<text x="30" y="742" font-family={JP!r} font-size="10" fill="{MAPLBL}">日比谷公園</text>
<text x="296" y="452" font-family={JP!r} font-size="12" font-weight="600" fill="#6F6759">東京駅</text>
<text x="214" y="268" font-family={JP!r} font-size="10" fill="{MAPLBL}">丸の内</text>
<text x="352" y="640" font-family={JP!r} font-size="10" fill="{MAPLBL}">八重洲</text>
<text x="330" y="176" font-family={JP!r} font-size="10" fill="{MAPLBL}">日本橋</text>
</svg>'''

def user_dot(x, y, heading=True):
    cone = (f'<path d="M{x-17} {y-6} A18 18 0 0 1 {x+17} {y-6} L{x} {y} Z" fill="{SYS_BLUE}" opacity="0.22"/>') if heading else ""
    return (f'<circle cx="{x}" cy="{y}" r="22" fill="{SYS_BLUE}" opacity="0.15"/>{cone}'
            f'<circle cx="{x}" cy="{y}" r="10.5" fill="#fff"/><circle cx="{x}" cy="{y}" r="8" fill="{SYS_BLUE}"/>')

def marker(x, y, color=RED, label=None):
    """MapKit の Marker（丸いバルーン）。"""
    t = (f'<text x="{x}" y="{y+30}" text-anchor="middle" font-family={JP!r} font-size="11" font-weight="600"'
         f' fill="#3C3C43" stroke="#fff" stroke-width="3" paint-order="stroke">{label}</text>') if label else ""
    return (f'<path d="M{x} {y+4} l-9 -13 a11 11 0 1 1 18 0 Z" fill="{color}"/>'
            f'<circle cx="{x}" cy="{y-12}" r="11.5" fill="{color}" stroke="#fff" stroke-width="2.4"/>'
            f'<circle cx="{x}" cy="{y-12}" r="4" fill="#fff"/>{t}')

def map_city(w=414, h=896, route="", extra="", vb="0 0 414 896"):
    """東京スケール。ルート提示・待機画面・探索ドライブで使う。"""
    roads = "".join([
        _rd("M-20 300 C 120 320, 250 330, 434 300", 4),
        _rd("M-20 470 C 110 470, 260 450, 434 430", 4),
        _rd("M-20 640 C 120 620, 250 600, 434 560", 4),
        _rd("M90 -20 C 110 200, 120 420, 150 916", 4),
        _rd("M250 -20 C 240 220, 250 420, 300 916", 4),
        _rd("M30 120 C 160 260, 230 330, 434 210", 3.4),
        _rd("M60 780 C 180 700, 260 560, 434 500", 3.4),
        _rd("M175 330 m -62 0 a62 62 0 1 0 124 0 a62 62 0 1 0 -124 0", 6, "hwy"),
        _rd("M175 268 C 150 180, 120 90, 100 -20", 5.5, "hwy"),
        _rd("M237 330 C 320 340, 380 330, 434 300", 5.5, "hwy"),
        _rd("M175 392 C 190 520, 230 640, 270 916", 5.5, "hwy"),
    ])
    return f'''<svg width="{w}" height="{h}" viewBox="{vb}" preserveAspectRatio="xMidYMid slice" style="display:block">
<rect x="-400" y="-400" width="1400" height="1800" fill="{LAND}"/>
<path d="M300 500 C 350 470, 390 430, 434 400 L434 916 L170 916 C 210 800, 250 620, 300 500 Z" fill="{WATER}"/>
<path d="M330 -20 C 336 120, 320 300, 300 470" fill="none" stroke="{WATER}" stroke-width="9"/>
<path d="M143 300 L207 296 L215 366 L150 372 Z" fill="{GREEN}"/>
<path d="M44 500 h64 v52 h-64 Z" fill="{GREEN}"/>
<path d="M286 150 h58 v62 h-58 Z" fill="{GREEN}"/>
{roads}{route}{extra}
<text x="152" y="326" font-family={JP!r} font-size="10" fill="{MAPLBL}">皇居</text>
<text x="46" y="432" font-family={JP!r} font-size="11" font-weight="600" fill="{MAPLBL}">新宿</text>
<text x="52" y="592" font-family={JP!r} font-size="11" font-weight="600" fill="{MAPLBL}">渋谷</text>
<text x="296" y="196" font-family={JP!r} font-size="10" fill="{MAPLBL}">上野</text>
<text x="196" y="716" font-family={JP!r} font-size="11" font-weight="600" fill="{MAPLBL}">品川</text>
<text x="352" y="560" font-family={JP!r} font-size="10" fill="{MAPLBL}">東京湾</text>
</svg>'''

def route_path(d, travelled=None, width=6):
    out = ""
    if travelled:
        out += f'<path d="{travelled}" fill="none" stroke="{TRAVELLED}" stroke-width="{width}" stroke-linecap="round" stroke-linejoin="round"/>'
    return (f'<path d="{d}" fill="none" stroke="{SYS_BLUE}" stroke-width="{width}" stroke-linecap="round" stroke-linejoin="round"/>' + out)


# ── 画面の部品（414x896pt の座標で描く）──────────────────────────
def panel(inner, bottom=None, top=None, extra=""):
    pos = f"bottom:{bottom}px;" if bottom is not None else f"top:{top}px;"
    return (f'<div style="position:absolute;left:16px;right:16px;{pos}padding:16px;border-radius:16px;'
            f'background:{MATERIAL};box-shadow:0 1px 12px rgba(0,0,0,0.10);{extra}">{inner}</div>')

def row(icon_svg, title, detail, title_size=12, detail_size=12, gap=10, title_weight=700):
    return (f'<div style="display:flex;align-items:flex-start;gap:{gap}px">'
            f'<div style="width:18px;display:flex;justify-content:center;padding-top:1px">{icon_svg}</div>'
            f'<div style="display:flex;flex-direction:column;gap:1px">'
            f'<div style="font-size:{title_size}px;font-weight:{title_weight};line-height:1.3">{title}</div>'
            f'<div style="font-size:{detail_size}px;color:{LABEL2};line-height:1.35">{detail}</div></div></div>')

def sun_icon(size=16, color=ORANGE):
    return (f'<svg width="{size}" height="{size}" viewBox="0 0 24 24" fill="none" style="display:block">'
            f'<path d="M4.6 16 a7.4 7.4 0 0 1 14.8 0 Z" fill="{color}"/>'
            f'<path d="M1.6 18.8 H22.4 M5.2 21.6 H18.8" stroke="{color}" stroke-width="1.9" stroke-linecap="round"/>'
            f'<path d="M12 2.2 V4.4 M3.5 5.6 L5 7.1 M20.5 5.6 L19 7.1" stroke="{color}" stroke-width="1.8" stroke-linecap="round"/></svg>')

def search_bar():
    return (f'<div style="display:flex;align-items:center;gap:8px;padding:12px;border-radius:12px;background:{MATERIAL};'
            f'color:{LABEL2};font-size:17px;box-shadow:0 1px 10px rgba(0,0,0,0.08)">'
            f'{icon("magnifyingglass",18,LABEL2)}<span>目的地を検索</span></div>')

def pin_chip(icon_svg, title, name):
    return (f'<div style="flex:1;display:flex;align-items:center;border-radius:12px;background:{MATERIAL};'
            f'box-shadow:0 1px 10px rgba(0,0,0,0.08)">'
            f'<div style="display:flex;align-items:center;gap:6px;padding:10px 0 10px 12px;flex:1">{icon_svg}'
            f'<div style="display:flex;flex-direction:column;gap:1px">'
            f'<div style="font-size:17px;line-height:1.2">{title}</div>'
            f'<div style="font-size:11px;color:{LABEL2};line-height:1.2">{name}</div></div></div>'
            f'<div style="padding:10px 12px">{icon("ellipsis.circle",18,LABEL3)}</div></div>')

def top_bar_idle():
    return (f'<div style="position:absolute;left:16px;right:16px;top:62px;display:flex;flex-direction:column;gap:8px">'
            f'{search_bar()}'
            f'<div style="display:flex;gap:8px">'
            f'{pin_chip(icon("house.fill",17,"#000"),"自宅","世田谷区三宿")}'
            f'{pin_chip(icon("bag.fill",17,"#000"),"職場","大手町ビルヂング")}</div></div>')

def map_controls(top=196):
    b = (f'<div style="width:44px;height:44px;border-radius:8px;background:{MATERIAL};display:flex;'
         f'align-items:center;justify-content:center;box-shadow:0 1px 8px rgba(0,0,0,0.10)">')
    return (f'<div style="position:absolute;right:16px;top:{top}px;display:flex;flex-direction:column;gap:10px">'
            f'{b}{icon("location.fill",19,SYS_BLUE)}</div>'
            f'{b}<svg width="21" height="21" viewBox="0 0 24 24"><circle cx="12" cy="12" r="9.4" fill="none" stroke="{LABEL2}" stroke-width="1.6"/>'
            f'<path d="M12 4.4 L14.6 12 L12 19.6 L9.4 12 Z" fill="{RED}"/><path d="M12 12 L14.6 12 L12 19.6 Z" fill="{LABEL2}"/></svg></div></div>')

def button(label, kind="bordered", size=17):
    if kind == "prominent":
        return (f'<div style="flex:1;text-align:center;padding:11px 0;border-radius:11px;background:{SYS_BLUE};'
                f'color:#fff;font-size:{size}px;font-weight:600">{label}</div>')
    if kind == "destructive":
        return (f'<div style="padding:8px 14px;border-radius:10px;background:rgba(255,59,48,0.12);'
                f'color:{RED};font-size:15px;font-weight:500">{label}</div>')
    return (f'<div style="flex:1;text-align:center;padding:11px 0;border-radius:11px;background:rgba(0,122,255,0.12);'
            f'color:{SYS_BLUE};font-size:{size}px">{label}</div>')

def screen(inner, w=414, h=896):
    return (f'<div style="position:relative;width:{w}px;height:{h}px;overflow:hidden;background:{LAND};color:#000;'
            f'font-size:17px;line-height:1.25;-webkit-font-smoothing:antialiased">{inner}</div>')


# ── 額装（キャプション＋端末）─────────────────────────────────
def artboard(caption_html, device_html, bg=SIGN_BLUE):
    return (f'<div style="position:relative;width:{W}px;height:{H}px;overflow:hidden;background:{bg};'
            f'color:#fff">{caption_html}{device_html}</div>')

def caption(l1, l2, sub):
    return (f'<div style="position:absolute;left:96px;right:96px;top:148px">'
            f'<div style="font-size:104px;font-weight:800;line-height:1.3;letter-spacing:0.01em">{l1}<br>{l2}</div>'
            f'<div style="margin-top:30px;font-size:40px;font-weight:500;line-height:1.5;'
            f'text-wrap:pretty;word-break:auto-phrase;color:rgba(255,255,255,0.74)">{sub}</div></div>')

def hi(text):
    return f'<span style="color:#FF5CB8">{text}</span>'

def phone(inner, top=566, scale=2.4, left=None):
    sw, sh, bez = round(414 * scale), round(896 * scale), 14
    fw = sw + bez * 2
    left = (W - fw) // 2 if left is None else left
    return (f'<div style="position:absolute;left:{left}px;top:{top}px;width:{fw}px;height:{sh+bez*2}px;'
            f'box-sizing:border-box;padding:{bez}px;border-radius:{round(39*scale)+bez}px;background:#0A0A0C;'
            f'box-shadow:0 40px 96px rgba(0,0,0,0.42)">'
            f'<div style="width:{sw}px;height:{sh}px;overflow:hidden;border-radius:{round(39*scale)}px">'
            f'<div style="width:414px;height:896px;transform:scale({scale});transform-origin:top left">{inner}</div>'
            f'</div></div>')

def head_unit(inner, top, scale, left=None):
    sw, sh, bez = round(800 * scale), round(480 * scale), 16
    fw = sw + bez * 2
    left = (W - fw) // 2 if left is None else left
    return (f'<div style="position:absolute;left:{left}px;top:{top}px;width:{fw}px;height:{sh+bez*2}px;'
            f'box-sizing:border-box;padding:{bez}px;border-radius:{24+bez}px;background:#0A0A0C;'
            f'box-shadow:0 40px 96px rgba(0,0,0,0.42)">'
            f'<div style="width:{sw}px;height:{sh}px;overflow:hidden;border-radius:24px">'
            f'<div style="width:800px;height:480px;transform:scale({scale});transform-origin:top left">{inner}</div>'
            f'</div></div>')

DOC = '''<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <script src="./support.js"></script>
</head>
<body>
<x-dc>
<helmet>
  <style>
    body { margin: 0; }
    .sc { font-family: %s; }
    a { color: #0067C0; } a:hover { color: #00457F; }
  </style>
</helmet>
<div class="sc">%s</div>
</x-dc>
</body>
</html>
''' % (JP, "%s")

def write(name, body):
    (OUT / name).write_text(DOC % body, encoding="utf-8")


# ── 1. 案内中 ────────────────────────────────────────────────
def screen_navigating():
    route = route_path("M200 700 V212 Q200 205 207 205 H600", travelled="M200 896 V700") + user_dot(200, 700)
    banner = (f'<div style="position:absolute;left:16px;right:16px;top:62px;display:flex;align-items:center;gap:16px;'
              f'background:{SYS_BLUE};border-radius:16px;padding:16px;color:#fff;box-shadow:0 4px 18px rgba(0,0,0,0.18)">'
              f'{icon("arrow.turn.up.right",32,"#fff",2.2)}'
              f'<div style="display:flex;flex-direction:column;gap:2px">'
              f'<div style="font-size:22px;font-weight:700;letter-spacing:-0.3px">500 m</div>'
              f'<div style="font-size:15px">永代通りへ右方向</div></div></div>')
    bottom = panel(
        f'<div style="display:flex;align-items:center;gap:12px">'
        f'<div style="flex:1;display:flex;flex-direction:column;gap:2px">'
        f'<div style="font-size:20px;font-weight:700">24分</div>'
        f'<div style="font-size:12px;color:{LABEL2}">8.4 km・15:30 着</div>'
        f'<div style="display:flex;align-items:center;gap:5px;margin-top:2px;font-size:12px;color:{PINK}">'
        f'{icon("sparkles",13,PINK)}<span>初めての道まで 1.2 km</span></div></div>'
        f'{button("案内終了","destructive")}</div>', bottom=34)
    return screen(f'<div style="position:absolute;inset:0">{map_street(route=route)}</div>'
                  f'{banner}{map_controls(200)}{bottom}')

# ── 2. ルート提示とドライブブリーフ ──────────────────────────────
def screen_preview():
    d = "M245 392 C 224 422, 208 450, 180 478 C 154 504, 128 524, 112 536"
    route = route_path(d) + marker(110, 540, RED, "渋谷駅") + user_dot(245, 392, heading=False)
    items = "".join([
        row(icon("exclamationmark.triangle.fill", 16, ORANGE), "経路上の注意", "通行料の支払いが必要です"),
        row(sun_icon(16), "西日への備え", "15:12 ごろから正面に西日が入ります。およそ 16分 続きます"),
        row(icon("sparkles", 16, SYS_BLUE), "初めての道", "全体の 38%・約 3.2 km"),
        row(icon("arrow.triangle.branch", 16, SYS_BLUE), "候補との違い", "最短時間・高速を使う"),
        row(icon("arrow.turn.up.right", 16, SYS_BLUE), "曲がる回数", "右折 6回・左折 4回"),
    ])
    chev_down = f'<span style="display:inline-block;transform:rotate(90deg)">{icon("chevron.right",13,LABEL3)}</span>'
    brief = (f'<div>'
             f'<div style="display:flex;align-items:center;gap:7px">{icon("car.side.fill",17,"#000")}'
             f'<span style="font-size:15px;font-weight:700">ドライブブリーフ</span>'
             f'<span style="flex:1"></span>{chev_down}</div>'
             f'<div style="display:flex;flex-direction:column;gap:10px;padding-top:8px">{items}</div></div>')
    departure = (f'<div style="display:flex;align-items:center;border-top:0.5px solid {SEP};padding-top:12px">'
                 f'<span style="font-size:15px">到着時刻から逆算</span><span style="flex:1"></span>'
                 f'{icon("chevron.right",13,LABEL3)}</div>')
    bottom = panel(
        f'<div style="display:flex;flex-direction:column;gap:12px">'
        f'<div style="font-size:17px;font-weight:700">渋谷駅</div>'
        f'<div style="font-size:15px;color:{LABEL2};margin-top:-6px">8.4 km・24分・15:30 着</div>'
        f'{brief}{departure}'
        f'<div style="display:flex;gap:12px">{button("やめる")}{button("案内開始","prominent")}</div></div>', bottom=34)
    return screen(f'<div style="position:absolute;inset:0">{map_city(route=route, vb="0 175 414 896")}</div>'
                  f'{top_bar_idle()}{bottom}')

# ── 3. 走破マップ ────────────────────────────────────────────
def map_region(w=414, h=280):
    lines = [
        [(300,150),(268,142),(238,132),(206,124),(176,116),(148,110),(118,100),(86,94),(48,88)],
        [(300,150),(296,166),(288,182),(276,198),(266,216)],
        [(300,150),(314,136),(326,118),(334,100),(338,84)],
        [(148,110),(140,132),(134,156),(126,180),(120,204)],
        [(300,150),(292,141),(305,135),(291,127),(302,120),(312,128)],
        [(266,216),(250,230),(232,240),(214,246)],
    ]
    cells = set()
    for pts in lines:
        for (x1,y1),(x2,y2) in zip(pts, pts[1:]):
            steps = max(2, int(max(abs(x2-x1), abs(y2-y1)) / 3))
            for i in range(steps + 1):
                x = x1 + (x2-x1)*i/steps
                y = y1 + (y2-y1)*i/steps
                cells.add((int(x//11)*11, int(y//11)*11))
    mesh = "".join(f'<rect x="{x}" y="{y}" width="11" height="11" fill="{MESH}"/>' for x, y in sorted(cells))
    tracks = "".join(
        '<polyline points="' + " ".join(f"{x},{y}" for x, y in pts) + f'" fill="none" stroke="{TRACK}" '
        f'stroke-width="3" stroke-linecap="round" stroke-linejoin="round" opacity="0.7"/>' for pts in lines)
    return f'''<svg width="{w}" height="{h}" viewBox="0 0 414 280" preserveAspectRatio="xMidYMid slice" style="display:block">
<rect width="414" height="280" fill="{LAND}"/>
<path d="M414 0 L352 0 C 344 58, 316 102, 306 142 C 300 178, 330 192, 380 202 C 316 212, 262 240, 238 280 L414 280 Z" fill="{WATER}"/>
<path d="M292 150 C 284 168, 276 186, 268 206" fill="none" stroke="{WATER}" stroke-width="5"/>
<ellipse cx="86" cy="140" rx="58" ry="40" fill="{GREEN}" opacity="0.85"/>
<ellipse cx="176" cy="182" rx="46" ry="30" fill="{GREEN}" opacity="0.75"/>
<ellipse cx="150" cy="70" rx="40" ry="26" fill="{GREEN}" opacity="0.7"/>
{_rd("M-20 150 C 120 130, 240 140, 434 120", 3)}{_rd("M300 -20 C 290 80, 280 180, 250 300", 3)}
{mesh}{tracks}
<text x="306" y="160" font-family={JP!r} font-size="10" font-weight="600" fill="{MAPLBL}">東京</text>
<text x="246" y="238" font-family={JP!r} font-size="9" fill="{MAPLBL}">横浜</text>
<text x="36" y="82" font-family={JP!r} font-size="9" fill="{MAPLBL}">甲府</text>
<text x="306" y="66" font-family={JP!r} font-size="9" fill="{MAPLBL}">千葉</text>
<text x="106" y="220" font-family={JP!r} font-size="9" fill="{MAPLBL}">小田原</text>
</svg>'''

def list_row(label, value, last=False):
    b = "none" if last else f"0.5px solid {SEP}"
    return (f'<div style="display:flex;align-items:center;justify-content:space-between;padding:12px 16px;'
            f'border-bottom:{b};font-size:17px"><span>{label}</span>'
            f'<span style="color:{LABEL2}">{value}</span></div>')

def screen_tracks():
    rows = (list_row("走った距離", "1,284 km") + list_row("開拓メッシュ", "612 マス")
            + list_row("走破エリア", "約 148.9 km²") + list_row("走った日", "46 日")
            + list_row("都道府県", "47 のうち 12") + list_row("市区町村", "88 か所", last=True))
    toggle_on = (f'<div style="width:51px;height:31px;border-radius:16px;background:#34C759;position:relative">'
                 f'<div style="position:absolute;right:2px;top:2px;width:27px;height:27px;border-radius:14px;'
                 f'background:#fff;box-shadow:0 2px 4px rgba(0,0,0,0.2)"></div></div>')
    sheet = (f'<div style="position:absolute;left:0;right:0;top:62px;bottom:0;background:#F2F2F7;'
             f'border-radius:12px 12px 0 0;overflow:hidden">'
             f'<div style="height:56px;display:flex;align-items:center;padding:0 16px;background:rgba(249,249,251,0.96);'
             f'border-bottom:0.5px solid {SEP}">'
             f'<span style="flex:1"></span><span style="font-size:17px;font-weight:700">走破マップ</span>'
             f'<span style="flex:1;text-align:right;font-size:17px;color:{SYS_BLUE}">閉じる</span></div>'
             f'<div style="margin:20px 16px 0;border-radius:10px;overflow:hidden">{map_region()}</div>'
             f'<div style="margin:18px 16px 0;border-radius:10px;overflow:hidden;background:#fff">{rows}</div>'
             f'<div style="margin:18px 16px 0;border-radius:10px;overflow:hidden;background:#fff">'
             f'<div style="display:flex;align-items:center;justify-content:space-between;padding:9px 16px;'
             f'border-bottom:0.5px solid {SEP};font-size:17px"><span>CarPlayで観光案内を読み上げる</span>{toggle_on}</div>'
             f'<div style="display:flex;align-items:center;justify-content:space-between;padding:12px 16px;font-size:17px">'
             f'<span>観光案内の出典</span>{icon("chevron.right",13,LABEL3)}</div></div></div>')
    return screen(f'<div style="position:absolute;inset:0">{map_city()}</div>'
                  f'<div style="position:absolute;inset:0;background:rgba(0,0,0,0.26)"></div>{sheet}')

# ── 4. 探索ドライブ ──────────────────────────────────────────
def screen_exploration():
    loop = ("M245 392 C 250 362, 252 330, 251 300 C 200 308, 148 314, 94 304 "
            "C 100 350, 104 404, 100 462 C 152 458, 202 430, 245 392 Z")
    route = route_path(loop) + user_dot(245, 392, heading=False)
    def opt(label):
        return (f'<div style="display:flex;align-items:center;gap:10px;padding:13px 14px;border-radius:11px;'
                f'background:rgba(255,45,85,0.12);color:{PINK}">{icon("clock",18,PINK)}'
                f'<span style="font-size:17px;font-weight:700">{label}</span><span style="flex:1"></span>'
                f'{icon("chevron.right",13,"rgba(255,45,85,0.5)")}</div>')
    sheet = (f'<div style="position:absolute;left:0;right:0;top:448px;bottom:0;background:#fff;'
             f'border-radius:12px 12px 0 0;overflow:hidden">'
             f'<div style="height:56px;display:flex;align-items:center;padding:0 16px;border-bottom:0.5px solid {SEP}">'
             f'<span style="flex:1;font-size:17px;color:{SYS_BLUE}">閉じる</span>'
             f'<span style="font-size:17px;font-weight:700">探索ドライブ</span><span style="flex:1"></span></div>'
             f'<div style="padding:16px;display:flex;flex-direction:column;gap:16px">'
             f'<div style="font-size:17px;color:{LABEL2};line-height:1.4">現在地へ戻る周回コースを、初めての道が多い順に探します</div>'
             f'{opt("約30分")}{opt("約1時間")}{opt("約1時間30分")}'
             f'<div style="font-size:12px;color:{LABEL2}">実際の所要時間は道路状況により前後します</div></div></div>')
    return screen(f'<div style="position:absolute;inset:0">{map_city(route=route)}</div>'
                  f'<div style="position:absolute;inset:0;background:rgba(0,0,0,0.22)"></div>{sheet}')

# ── 5. 到着の収穫 ────────────────────────────────────────────
def screen_harvest():
    def metric(icon_svg, value, label):
        return (f'<div style="flex:1;display:flex;align-items:flex-start;gap:8px">'
                f'<div style="width:18px;display:flex;justify-content:center;padding-top:3px">{icon_svg}</div>'
                f'<div style="display:flex;flex-direction:column;gap:2px">'
                f'<div style="font-size:20px;font-weight:700">{value}</div>'
                f'<div style="font-size:11px;color:{LABEL2}">{label}</div></div></div>')
    card = panel(
        f'<div style="display:flex;flex-direction:column;gap:14px">'
        f'<div style="display:flex;align-items:flex-start">'
        f'<div style="flex:1;display:flex;flex-direction:column;gap:2px">'
        f'<div style="display:flex;align-items:center;gap:6px;color:{PINK}">{icon("sparkles",17,PINK)}'
        f'<span style="font-size:17px;font-weight:700">今回の収穫</span></div>'
        f'<div style="font-size:12px;color:{LABEL2}">河口湖周辺までのドライブ</div></div>'
        f'{icon("xmark.circle.fill",20,"rgba(60,60,67,0.3)")}</div>'
        f'<div style="display:flex;gap:12px">'
        f'{metric(icon("map.fill",16,PINK),"山梨県","初めて走った都道府県")}'
        f'{metric(icon("building.2.fill",16,PINK),"3か所","初めて走った街")}</div>'
        f'<div style="display:flex;align-items:center;gap:6px">'
        f'{icon("flag.checkered",13,LABEL2)}'
        f'<span style="font-size:12px;color:{LABEL2}">通算12都道府県・88市区町村</span>'
        f'<span style="flex:1"></span>'
        f'<span style="font-size:12px;font-weight:700;color:{SYS_BLUE}">走破マップを見る</span></div></div>',
        bottom=190)
    def link_row(icon_svg, title, detail, bottom):
        return panel(f'<div style="display:flex;align-items:center;gap:10px">'
                     f'{icon_svg}<div style="flex:1;display:flex;flex-direction:column;gap:2px">'
                     f'<div style="font-size:17px">{title}</div>'
                     f'<div style="font-size:12px;color:{LABEL2}">{detail}</div></div>'
                     f'{icon("chevron.right",13,LABEL3)}</div>', bottom=bottom)
    return screen(f'<div style="position:absolute;inset:0">{map_city(route=user_dot(245,392,heading=False))}</div>'
                  f'{top_bar_idle()}{card}'
                  f'{link_row(icon("sparkles",19,PINK),"探索ドライブ","時間を選んで、初めての道が多い周回コースへ",112)}'
                  f'{link_row(icon("curvepath",19,SYS_BLUE),"走破マップ","1,284 km",34)}')


# ── 6. CarPlay ───────────────────────────────────────────────
def north_icon(size=20, color="#fff"):
    return (f'<svg width="{size}" height="{size}" viewBox="0 0 24 24" fill="none" style="display:block">'
            f'<path d="M12 3.4 L17.4 17.6 L12 14.2 L6.6 17.6 Z" fill="{color}"/>'
            f'<path d="M5.2 20.6 H18.8" stroke="{color}" stroke-width="1.9" stroke-linecap="round"/></svg>')

def cp_button(icon_svg, size=46):
    return (f'<div style="width:{size}px;height:{size}px;border-radius:12px;background:rgba(22,22,24,0.62);'
            f'display:flex;align-items:center;justify-content:center">{icon_svg}</div>')

def screen_carplay():
    tracks = "".join(f'<path d="{d}" fill="none" stroke="{TRACK}" stroke-width="4" stroke-linecap="round" opacity="0.42"/>'
                     for d in ["M380 -180 V1080", "M-180 560 H600", "M125 -180 V700", "M-180 295 H320"])
    route = route_path("M200 480 V212 Q200 205 207 205 H600", travelled="M200 896 V480") + user_dot(200, 480)
    card = (f'<div style="position:absolute;left:12px;top:64px;width:322px;background:{SIGN_BLUE};border-radius:14px;'
            f'padding:14px;display:flex;align-items:center;gap:14px;color:#fff;box-shadow:0 6px 22px rgba(0,0,0,0.3)">'
            f'{icon("arrow.turn.up.right",42,"#fff",2.1)}'
            f'<div style="display:flex;flex-direction:column;gap:3px">'
            f'<div style="font-size:30px;font-weight:700;letter-spacing:-0.4px">500 m</div>'
            f'<div style="font-size:17px;line-height:1.25">永代通りへ右方向</div></div></div>')
    topbar = (f'<div style="position:absolute;left:0;right:0;top:0;height:52px;background:rgba(18,18,20,0.5);'
              f'display:flex;align-items:center;gap:10px;padding:0 12px">'
              f'{cp_button(icon("mic.fill",20,"#fff"),40)}'
              f'{cp_button(icon("arrow.up.left.and.arrow.down.right",20,"#fff"),40)}'
              f'<span style="flex:1"></span>'
              f'{cp_button(icon("speaker.wave.2.fill",20,"#fff"),40)}'
              f'{cp_button(icon("xmark",20,"#fff"),40)}</div>')
    buttons = (f'<div style="position:absolute;right:12px;top:76px;display:flex;flex-direction:column;gap:12px">'
               f'{cp_button(icon("hand.draw",22,"#fff"))}{cp_button(icon("plus",22,"#fff"))}'
               f'{cp_button(icon("minus",22,"#fff"))}{cp_button(north_icon(21))}</div>')
    tray = (f'<div style="position:absolute;left:12px;bottom:14px;display:flex;align-items:baseline;'
            f'gap:10px;padding:12px 22px;border-radius:14px;background:rgba(18,18,20,0.62);color:#fff">'
            f'<span style="font-size:22px;font-weight:700">24分</span>'
            f'<span style="font-size:16px;color:rgba(255,255,255,0.82)">8.4 km</span>'
            f'<span style="font-size:16px;color:rgba(255,255,255,0.82)">15:30 着</span></div>')
    return (f'<div style="position:relative;width:800px;height:480px;overflow:hidden;background:{LAND}">'
            f'<div style="position:absolute;inset:0">'
            f'{map_street(route=route, tracks=tracks, w=800, h=480, vb="30 302 360 216")}</div>'
            f'{topbar}{card}{buttons}{tray}</div>')

# ── 方向性の別案（低精細）─────────────────────────────────────
def sketch_phone(left, top, w, h, dark=False):
    bg = "#D8D4CC" if not dark else "#3A3A3C"
    return (f'<div style="position:absolute;left:{left}px;top:{top}px;width:{w}px;height:{h}px;border-radius:{w//12}px;'
            f'background:{bg};box-shadow:0 20px 50px rgba(0,0,0,0.25)">'
            f'<div style="position:absolute;left:6%;right:6%;top:5%;height:7%;border-radius:22px;background:#9C9C9C"></div>'
            f'<div style="position:absolute;left:6%;right:6%;bottom:5%;height:12%;border-radius:22px;background:#BDBDBD"></div></div>')

def direction_a():
    return artboard(
        f'<div style="position:absolute;left:96px;right:96px;top:170px;color:#1A1A1A">'
        f'<div style="font-size:104px;font-weight:800;line-height:1.3">はじめての道を、<br>数えるカーナビ。</div>'
        f'<div style="margin-top:28px;font-size:42px;color:#6B6B70">明るい地に黒文字。端末は下に大きく。</div></div>',
        sketch_phone(111, 640, 1020, 2100), bg="#F2EFE9")

def direction_b():
    return artboard(
        f'<div style="position:absolute;left:0;right:0;top:0;bottom:0">'
        f'<div style="position:absolute;left:0;right:0;top:0;height:2160px;background:#D8D4CC"></div>'
        f'<div style="position:absolute;left:60px;right:60px;top:80px;height:170px;border-radius:28px;background:#9C9C9C"></div>'
        f'<div style="position:absolute;left:0;right:0;bottom:0;height:528px;background:{SIGN_BLUE};'
        f'display:flex;flex-direction:column;justify-content:center;padding:0 96px">'
        f'<div style="font-size:96px;font-weight:800;line-height:1.3;color:#fff">はじめての道を、<br>数えるカーナビ。</div>'
        f'</div></div>', "", bg="#0A0A0C")

# ── 組み立て ─────────────────────────────────────────────────
SHEETS = [
    ("Main.dc.html", caption(f'{hi("はじめての道")}を、', "数えるカーナビ。",
                             "走った道が地図に残り、初めての街が貯まっていく。"),
     lambda: phone(screen_navigating())),
    ("Brief.dc.html", caption("出発前に、", "知りたいことだけ。",
                              "初めての道の割合・西日・曲がる回数・経路上の注意。"),
     lambda: phone(screen_preview())),
    ("Tracks.dc.html", caption("走った道が、", f'地図に{hi("貯まる")}。',
                               "走破メッシュと、通った市区町村の記録。"),
     lambda: phone(screen_tracks())),
    ("Exploration.dc.html", caption("時間だけ決めて、", f'{hi("知らない道")}へ。',
                                    "30・60・90 分から選ぶと、現在地へ戻る周回コースを提案。"),
     lambda: phone(screen_exploration())),
    ("Harvest.dc.html", caption("着いたら、", f'今日の{hi("収穫")}を。',
                                "初めて走った都道府県と街。通算はマイルのように貯まる。"),
     lambda: phone(screen_harvest())),
    ("CarPlay.dc.html", caption("車の画面でも、", "同じ案内。",
                                "センターディスプレイ・Dashboard・メーター内に対応。"),
     lambda: head_unit(screen_carplay(), top=700, scale=1.42, left=60) + phone(screen_navigating(), top=1524, scale=1.5, left=520)),
]

def main():
    for name, cap, device in SHEETS:
        write(name, artboard(cap, device()))
    write("DirectionA.dc.html", direction_a())
    write("DirectionB.dc.html", direction_b())

    gap = 140
    boards = [{"file": n, "x": i * (W + gap), "y": 0, "w": W, "h": H} for i, (n, _, _) in enumerate(SHEETS)]
    boards += [{"file": "DirectionA.dc.html", "x": 0, "y": H + 300, "w": W, "h": H},
               {"file": "DirectionB.dc.html", "x": W + gap, "y": H + 300, "w": W, "h": H}]
    canvas = {
        "artboards": boards,
        "annotations": [
            {"id": "note-size", "x": 0, "y": -220, "w": 900,
             "text": "App Store 用 1242×2688px（6.5インチ）。左から 1〜6 枚目の並び。"},
            {"id": "note-alts", "x": 0, "y": H + 120, "w": 900,
             "text": "見せ方の別案（低精細）。A＝明るい地に黒文字、B＝画面を全面に出して下帯にコピー。"},
        ],
        "launch": {"view": "canvas"},
    }
    (OUT / "canvas.json").write_text(json.dumps(canvas, ensure_ascii=False, indent=2), encoding="utf-8")

    # 自分で見るための確認用（配布物ではない）
    boards_html = [artboard(c, d()) for _, c, d in SHEETS] + [direction_a(), direction_b()]
    cells = "".join(
        f'<div style="width:{int(W*0.24)}px;height:{int(H*0.24)}px;overflow:hidden">'
        f'<div style="transform:scale(0.24);transform-origin:top left;width:{W}px;height:{H}px">{a}</div></div>'
        for a in boards_html)
    (OUT / "preview.html").write_text(
        f'<!doctype html><meta charset="utf-8"><body style="margin:0;background:#555;font-family:{JP.replace(chr(34), chr(39))}">'
        f'<div style="display:flex;flex-wrap:wrap">{cells}</div></body>', encoding="utf-8")
    print("wrote", len(SHEETS) + 2, "artboards")

main()
