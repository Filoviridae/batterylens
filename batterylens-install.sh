#!/usr/bin/env bash
# BatteryLens — One-click installer
# https://github.com/Filoviridae/batterylens
set -e
APP_DIR="$HOME/.local/share/batterylens"
BIN_DIR="$HOME/.local/bin"
DESKTOP_DIR="$HOME/.local/share/applications"
APP_FILE="$APP_DIR/battery_lens_gtk.py"
ICON_SRC="$APP_DIR/batterylens-icon.png"
ICON_THEME_DIR="$HOME/.local/share/icons/hicolor/256x256/apps"
ICON_THEME_FILE="$ICON_THEME_DIR/batterylens.png"
LAUNCHER="$BIN_DIR/batterylens"
VENV_DIR="$APP_DIR/venv"
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; RESET='\033[0m'
ok()   { echo -e "  ${GREEN}✓${RESET} $*"; }
info() { echo -e "  ${BLUE}→${RESET} $*"; }
warn() { echo -e "  ${YELLOW}⚠${RESET}  $*"; }
die()  { echo -e "\n  ${RED}✗  $*${RESET}\n"; exit 1; }
echo ""
echo -e "${BOLD}🔋 BatteryLens Installer${RESET}"
echo "────────────────────────────────────────"
echo ""
info "Checking Python 3..."
python3 --version &>/dev/null || die "Python 3 not found."
ok "Python 3 found ($(python3 --version 2>&1))"
info "Checking GTK3 + PyGObject..."
if python3 -c "import gi; gi.require_version('Gtk','3.0'); from gi.repository import Gtk" &>/dev/null; then
    ok "GTK3 + PyGObject available"
else
    sudo dnf install -y python3-gobject python3-gobject-devel || die "Could not install PyGObject"
    ok "PyGObject installed"
fi
info "Checking pycairo..."
if python3 -c "import cairo" &>/dev/null; then
    ok "pycairo available"
else
    sudo dnf install -y python3-cairo || die "Could not install pycairo"
    ok "pycairo installed"
fi
info "Installing app to $APP_DIR..."
mkdir -p "$APP_DIR" "$BIN_DIR" "$DESKTOP_DIR"
cat > "$APP_FILE" << 'BATTERYLENS_APP_END'
#!/usr/bin/env python3
"""
BatteryLens - GTK3 native battery charge history viewer
Version: 1.0.0
Repository: https://github.com/Filoviridae/batterylens
"""

import gi
gi.require_version('Gtk', '3.0')
gi.require_version('Gdk', '3.0')
from gi.repository import Gtk, Gdk, GLib, GdkPixbuf, Gio

import os
import sys
import glob
import json
import time
import math
import datetime
import threading
import subprocess
import urllib.request
import urllib.error
import io
import base64

import matplotlib
matplotlib.use('cairo')
import matplotlib.pyplot as plt
import matplotlib.patches as mpatches
import numpy as np
from matplotlib.backends.backend_cairo import FigureCanvasCairo, RendererCairo

VERSION = "1.0.0"
REPO = "Filoviridae/batterylens"
SLEEP_GAP_THRESHOLD_S = 900  # 15 min

APP_DIR   = os.path.expanduser('~/.local/share/batterylens')
HIDDEN_FILE = os.path.join(APP_DIR, 'hidden_sessions.json')
ICON_PATH   = os.path.join(APP_DIR, 'batterylens-icon.png')

# ── Colour palette (matches original dark theme) ─────────────────────────────
BG      = '#1C1C1E'
BG2     = '#2C2C2E'
BG3     = '#3A3A3C'
TEXT    = '#FFFFFF'
SUBTEXT = '#8E8E93'
GREAT   = '#34C759'
GOOD    = '#30B0C7'
FAIR    = '#FF9F0A'
POOR    = '#FF3B30'
ACTIVE  = '#007AFF'
SLEEP_LINE = '#6E6E7A'

RATING_COLORS = {'great': GREAT, 'good': GOOD, 'fair': FAIR,
                 'poor': POOR, 'active': ACTIVE, 'light': SUBTEXT}

# ── CSS ───────────────────────────────────────────────────────────────────────
CSS = """
* { font-family: "Inter", "Cantarell", sans-serif; }

/* Force dark background on ALL widgets */
window,
box, grid, scrolledwindow, viewport,
stack, paned, frame, eventbox,
listbox, listboxrow {
    background-color: #1C1C1E;
    color: #FFFFFF;
}

/* Kill GTK's default button chrome entirely */
button {
    background: none;
    background-image: none;
    border: none;
    border-radius: 8px;
    box-shadow: none;
    color: #8E8E93;
    padding: 6px 12px;
    outline: none;
}
button:hover { background-color: #3A3A3C; color: #FFFFFF; }
button:active { background-color: #3A3A3C; }
button:focus { outline: none; box-shadow: none; }

/* Scrollbar */
scrollbar { background-color: #1C1C1E; }
scrollbar slider { background-color: #3A3A3C; border-radius: 4px; min-width: 4px; min-height: 4px; }

/* Paned divider */
paned > separator { background-color: #3A3A3C; min-width: 1px; }

/* ListBox rows — no hover highlight by default */
listboxrow { background-color: transparent; }
listboxrow:hover { background-color: transparent; }

/* Dialog */
dialog { background-color: #2C2C2E; }
dialog box { background-color: #2C2C2E; }
.dialog-action-area { background-color: #2C2C2E; }

/* ── Sidebar ── */
#sidebar { background-color: #141416; border-right: 1px solid #3A3A3C; }
#sidebar-header { padding: 20px 20px 12px 20px; border-bottom: 1px solid #3A3A3C; background-color: #141416; }
#app-name { font-size: 20px; font-weight: 800; color: #FFFFFF; }
#header-sub { font-size: 12px; color: #8E8E93; margin-top: 2px; }

/* ── Stats row ── */
.stat-box {
    background-color: #2C2C2E;
    border-radius: 10px;
    padding: 8px 10px;
    margin: 2px;
}
.stat-val { font-size: 15px; font-weight: 700; color: #FFFFFF; }
.stat-lbl { font-size: 9px; color: #8E8E93; }

/* ── Section header ── */
.section-header {
    font-size: 10px;
    font-weight: 700;
    color: #8E8E93;
    padding: 8px 20px 4px 20px;
    background-color: #141416;
}

/* ── Session list background ── */
#session-list-scroll,
#session-list-scroll viewport,
#session-list-scroll listbox {
    background-color: #141416;
}

/* ── Session cards ── */
.session-row {
    background-color: #2C2C2E;
    border-radius: 12px;
    margin: 3px 10px;
    padding: 10px 12px;
}
.session-row:hover { background-color: #3A3A3C; }
.session-date { font-size: 13px; font-weight: 600; color: #FFFFFF; }
.session-time { font-size: 11px; color: #8E8E93; }
.session-duration { font-size: 15px; font-weight: 700; }
.session-range { font-size: 10px; color: #8E8E93; }
.active-badge {
    background-color: rgba(0,122,255,0.15);
    border-radius: 6px;
    padding: 2px 8px;
    font-size: 10px;
    color: #007AFF;
    font-weight: 600;
}

/* ── Restore button ── */
#restore-btn {
    background-color: #2C2C2E;
    border: none;
    border-radius: 8px;
    color: #8E8E93;
    font-size: 11px;
    font-weight: 600;
    padding: 6px 12px;
    margin: 6px 10px;
}
#restore-btn:hover { background-color: #3A3A3C; color: #FFFFFF; }

/* ── Restore footer area ── */
#restore-footer { background-color: #141416; border-top: 1px solid #3A3A3C; padding: 6px; }

/* ── Main panel ── */
#main-panel { background-color: #1C1C1E; }

/* ── Tab bar ── */
#tab-bar { background-color: #1C1C1E; border-bottom: 1px solid #3A3A3C; }
.tab-btn {
    background: none;
    border: none;
    border-bottom: 2px solid transparent;
    border-radius: 0;
    color: #8E8E93;
    font-size: 13px;
    font-weight: 600;
    padding: 12px 16px;
}
.tab-btn:hover { background: none; color: #FFFFFF; }
.tab-btn-active { color: #FFFFFF; border-bottom-color: #007AFF; }

/* ── Update / refresh buttons ── */
#update-btn, #refresh-btn {
    background: none;
    border: none;
    border-radius: 8px;
    color: #8E8E93;
    font-size: 11px;
    padding: 4px 10px;
}
#update-btn:hover, #refresh-btn:hover { background-color: #2C2C2E; color: #FFFFFF; }

/* ── Detail header ── */
#detail-title { font-size: 26px; font-weight: 800; }
#detail-subtitle { font-size: 13px; color: #8E8E93; margin-top: 3px; }
#detail-header { padding: 24px 28px 16px 28px; border-bottom: 1px solid #3A3A3C; background-color: #1C1C1E; }

/* ── Stat cards ── */
.stat-card {
    background-color: #2C2C2E;
    border-radius: 14px;
    padding: 14px 16px;
    margin: 4px;
}
.stat-card-val { font-size: 22px; font-weight: 700; }
.stat-card-lbl { font-size: 10px; color: #8E8E93; margin-top: 3px; }

/* ── Chart card ── */
.chart-card {
    background-color: #2C2C2E;
    border-radius: 14px;
    padding: 16px;
    margin: 4px;
}
.chart-label { font-size: 11px; font-weight: 600; color: #8E8E93; margin-bottom: 8px; }

/* ── Overview battery strip ── */
.bat-strip {
    background-color: #2C2C2E;
    border-radius: 14px;
    padding: 12px 16px;
    margin: 4px;
}
.bat-model { font-size: 13px; font-weight: 600; color: #FFFFFF; }
.bat-detail { font-size: 11px; color: #8E8E93; margin-top: 2px; }
.bat-pct { font-size: 22px; font-weight: 800; color: #FFFFFF; }

/* ── Empty state ── */
.empty-title { font-size: 17px; font-weight: 600; color: #8E8E93; }
.empty-sub { font-size: 13px; color: #8E8E93; }

/* ── Sleep note ── */
.sleep-note {
    background-color: rgba(74,74,90,0.25);
    border-radius: 8px;
    border-left: 3px solid #6E6E7A;
    padding: 8px 12px;
    margin: 4px;
    font-size: 11px;
    color: #8E8E93;
}

/* ── Estimate panel ── */
.estimate-val { font-size: 22px; font-weight: 700; }
.estimate-lbl { font-size: 9px; color: #8E8E93; }
.estimate-rate { font-size: 11px; color: #8E8E93; }
"""


# ═══════════════════════════════════════════════════════════════════════════════
# DATA LAYER  (identical logic to Flask version, no HTTP)
# ═══════════════════════════════════════════════════════════════════════════════

def _read_sys_battery():
    info = {}
    for bat_path in glob.glob('/sys/class/power_supply/BAT*'):
        name = os.path.basename(bat_path)
        bat = {'name': name}
        for key in ['capacity', 'status', 'energy_now', 'energy_full',
                    'charge_now', 'charge_full', 'voltage_now', 'current_now',
                    'power_now', 'manufacturer', 'model_name', 'technology',
                    'cycle_count', 'capacity_level']:
            fpath = os.path.join(bat_path, key)
            if os.path.exists(fpath):
                try:
                    with open(fpath) as f:
                        bat[key] = f.read().strip()
                except Exception:
                    pass
        info[name] = bat
    return info

def _read_upower_history():
    all_entries = []
    for fpath in glob.glob('/var/lib/upower/history-charge-*.dat'):
        try:
            with open(fpath) as f:
                for line in f:
                    line = line.strip()
                    if not line or line.startswith('#'):
                        continue
                    parts = line.split('\t')
                    if len(parts) >= 3:
                        try:
                            ts  = int(parts[0])
                            val = float(parts[1])
                            state = parts[2].strip()
                            all_entries.append({
                                'ts': ts, 'val': val, 'state': state,
                                'dt': datetime.datetime.fromtimestamp(ts)
                            })
                        except (ValueError, OSError):
                            pass
        except (IOError, PermissionError):
            pass
    if not all_entries:
        return None
    all_entries.sort(key=lambda x: x['ts'])
    return _extract_sessions(all_entries)

def _extract_sessions(entries):
    sessions = []
    current = None

    def _close(cur, active=False):
        if not cur or len(cur['points']) < 2:
            return None
        last = cur['points'][-1]
        cur['end']      = last['dt']
        cur['end_ts']   = last['ts']
        cur['end_pct']  = last['val']
        cur['duration_h'] = (cur['end_ts'] - cur['start_ts']) / 3600
        if cur['duration_h'] < 0.08:
            return None
        s = _finalize(cur)
        s['active'] = active
        return s

    for e in entries:
        if e['state'] == 'discharging':
            if current is None:
                current = {'start': e['dt'], 'start_ts': e['ts'],
                           'start_pct': e['val'], 'points': [e]}
            else:
                current['points'].append(e)
        else:
            s = _close(current)
            if s:
                sessions.append(s)
            current = None

    if current and len(current['points']) >= 2:
        last = current['points'][-1]
        recency_s = time.time() - last['ts']
        is_active = recency_s < 1800
        s = _close(current, active=is_active)
        if s:
            sessions.append(s)

    return sessions

def _finalize(s):
    pts   = s['points']
    drain = s['start_pct'] - s['end_pct']
    dur_h = s['duration_h']

    intervals = [pts[i]['ts'] - pts[i-1]['ts'] for i in range(1, len(pts))]
    active_s = 0
    sleep_gaps = []
    for i in range(1, len(pts)):
        gap = pts[i]['ts'] - pts[i-1]['ts']
        if gap > SLEEP_GAP_THRESHOLD_S:
            sleep_gaps.append((pts[i-1]['ts'], pts[i]['ts']))
        else:
            active_s += gap
    active_h = active_s / 3600

    if drain > 0 and active_h > 0:
        full_equiv_h = active_h * (100 / drain)
    elif drain > 0:
        full_equiv_h = dur_h * (100 / drain)
    else:
        full_equiv_h = active_h or dur_h

    if active_h < 0.5:    usage = 'light'
    elif full_equiv_h >= 7:   usage = 'great'
    elif full_equiv_h >= 4.5: usage = 'good'
    elif full_equiv_h >= 2.5: usage = 'fair'
    else:                     usage = 'poor'

    return {
        'start': s['start'], 'end': s['end'],
        'start_ts': s['start_ts'], 'end_ts': s['end_ts'],
        'start_pct': round(s['start_pct']),
        'end_pct':   round(s['end_pct']),
        'duration_h':  dur_h,
        'active_h':    round(active_h, 3),
        'full_equiv_h': full_equiv_h,
        'drain_pct':   round(drain),
        'usage_rating': usage,
        'sleep_gaps':  sleep_gaps,
        'points':      pts,
        'active':      False,
    }

def fmt_duration(hours):
    h = int(hours)
    m = int((hours - h) * 60)
    if h == 0: return f"{m}m"
    if m == 0: return f"{h}h"
    return f"{h}h {m}m"

def fmt_time_range(start_dt, end_dt):
    s = start_dt.strftime('%-I:%M %p')
    e = end_dt.strftime('%-I:%M %p')
    if start_dt.date() != end_dt.date():
        e = end_dt.strftime('%b %-d, ') + e
    return f"{s} – {e}"

def get_battery_info():
    info = _read_sys_battery()
    if not info:
        return None
    b = list(info.values())[0]
    drain_w = 0.0
    try:
        pn = int(b.get('power_now', 0))
        if pn > 0:
            drain_w = pn / 1_000_000
    except Exception:
        pass
    if drain_w == 0:
        try:
            v = int(b.get('voltage_now', 0)) / 1_000_000
            i = int(b.get('current_now', 0)) / 1_000_000
            drain_w = v * abs(i)
        except Exception:
            pass
    return {
        'status':     b.get('status', 'Unknown'),
        'capacity':   b.get('capacity', '?'),
        'model':      b.get('model_name', b.get('manufacturer', 'Battery')),
        'technology': b.get('technology', ''),
        'cycle_count': b.get('cycle_count', ''),
        'drain_w':    round(drain_w, 2),
    }


# ── Hidden sessions persistence ───────────────────────────────────────────────

def load_hidden_ts():
    try:
        with open(HIDDEN_FILE) as f:
            return set(json.load(f))
    except (FileNotFoundError, json.JSONDecodeError):
        return set()

def save_hidden_ts(ts_set):
    try:
        with open(HIDDEN_FILE, 'w') as f:
            json.dump(list(ts_set), f)
    except Exception:
        pass

def resolve_hidden_idxs(sessions, hidden_ts):
    result = set()
    for i, s in enumerate(sessions):
        if int(s['start_ts']) in hidden_ts:
            result.add(i)
    return result


# ═══════════════════════════════════════════════════════════════════════════════
# CHART LAYER  (matplotlib → Cairo surface → Gtk.DrawingArea)
# ═══════════════════════════════════════════════════════════════════════════════

def _fig_to_pixbuf(fig, dpi=150):
    """Render a matplotlib figure to a GdkPixbuf via PNG."""
    buf = io.BytesIO()
    fig.savefig(buf, format='png', dpi=dpi, bbox_inches='tight',
                facecolor=fig.get_facecolor())
    buf.seek(0)
    loader = GdkPixbuf.PixbufLoader.new_with_type('png')
    loader.write(buf.read())
    loader.close()
    return loader.get_pixbuf()

def _smart_xticks(ax, max_h):
    nice = [0.5, 1, 2, 3, 4, 6, 8, 12, 24]
    step = nice[-1]
    for s in nice:
        if 4 <= max_h / s <= 9:
            step = s
            break
    ticks = np.arange(0, max_h + step, step)
    ax.set_xticks(ticks)
    ax.set_xticklabels([f'{x:.0f}h' if x == int(x) else f'{x:.1f}h' for x in ticks],
                       color=SUBTEXT, fontsize=8)

def _style_ax(ax, fig):
    ax.set_facecolor(BG2)
    fig.patch.set_facecolor(BG2)
    ax.yaxis.grid(True, color=BG3, linewidth=0.7)
    ax.set_axisbelow(True)
    ax.xaxis.grid(False)
    ax.spines['top'].set_visible(False)
    ax.spines['right'].set_visible(False)
    ax.spines['bottom'].set_color(BG3)
    ax.spines['left'].set_visible(False)
    ax.tick_params(colors=SUBTEXT, which='both', length=0)
    ax.set_yticks([0, 25, 50, 75, 100])
    ax.set_yticklabels(['0%', '25%', '50%', '75%', '100%'], color=SUBTEXT, fontsize=8)

def _draw_discharge_line(ax, pts, xs, ys, color):
    """Draw solid line for active periods, dashed for sleep gaps."""
    active_xs, active_ys = [xs[0]], [ys[0]]
    any_sleep = False
    first_sleep = True
    first_active = [True]

    def flush(rxs, rys):
        if len(rxs) < 2:
            return
        ax.fill_between(rxs, rys, alpha=0.2, color=color, zorder=3)
        lbl = 'Active' if first_active[0] else None
        ax.plot(rxs, rys, color=color, linewidth=2.5,
                solid_capstyle='round', zorder=5, label=lbl)
        if first_active[0]:
            ax.plot(rxs[0], rys[0], 'o', color=color, markersize=7,
                    zorder=6, markerfacecolor=BG2, markeredgewidth=2)
            first_active[0] = False

    for i in range(1, len(pts)):
        gap = pts[i]['ts'] - pts[i-1]['ts']
        if gap > SLEEP_GAP_THRESHOLD_S:
            any_sleep = True
            flush(active_xs, active_ys)
            lbl = 'Sleeping' if first_sleep else None
            ax.plot([xs[i-1], xs[i]], [ys[i-1], ys[i]],
                    color=SLEEP_LINE, linewidth=1.5, linestyle='--',
                    alpha=0.7, zorder=4, label=lbl)
            first_sleep = False
            active_xs, active_ys = [xs[i]], [ys[i]]
        else:
            active_xs.append(xs[i])
            active_ys.append(ys[i])

    flush(active_xs, active_ys)
    ax.plot(xs[-1], ys[-1], 'o', color=color, markersize=7, zorder=6)

    if any_sleep:
        ax.legend(fontsize=8, facecolor=BG2, edgecolor=BG3,
                  labelcolor=SUBTEXT, loc='upper right')

def make_detail_pixbuf(session, dpi=150):
    pts = session['points']
    xs  = [(p['ts'] - pts[0]['ts']) / 3600 for p in pts]
    ys  = [p['val'] for p in pts]
    color = RATING_COLORS.get(
        'active' if session.get('active') else session['usage_rating'], GOOD)

    fig, ax = plt.subplots(figsize=(6.5, 2.8))
    _style_ax(ax, fig)
    ax.set_xlim(min(xs) - 0.05, max(xs) + 0.05)
    ax.set_ylim(max(0, min(ys) - 10), 108)
    _draw_discharge_line(ax, pts, xs, ys, color)
    _smart_xticks(ax, max(xs))
    plt.tight_layout(pad=0.4)
    pb = _fig_to_pixbuf(fig, dpi)
    plt.close(fig)
    return pb

def make_overview_pixbuf(sessions, dpi=150):
    recent = [s for s in sessions if not s.get('active')][:10]
    recent.reverse()
    if not recent:
        return None
    labels = [s['start'].strftime('%b %-d') for s in recent]
    values = [min(s['full_equiv_h'], 14) for s in recent]
    colors = [RATING_COLORS.get(s['usage_rating'], GOOD) for s in recent]

    fig, ax = plt.subplots(figsize=(6.5, 2.5))
    _style_ax(ax, fig)
    bars = ax.bar(range(len(labels)), values, color=colors, width=0.6, zorder=3)
    for bar, val in zip(bars, values):
        ax.text(bar.get_x() + bar.get_width() / 2, bar.get_height() + 0.1,
                f'{val:.1f}h', ha='center', va='bottom',
                color=TEXT, fontsize=7.5, fontweight='600')
    ax.set_xticks(range(len(labels)))
    ax.set_xticklabels(labels, color=SUBTEXT, fontsize=8)
    ax.set_ylim(0, max(values) * 1.35 + 0.5)
    ax.set_yticks([])
    ax.spines['left'].set_visible(False)
    plt.tight_layout(pad=0.4)
    pb = _fig_to_pixbuf(fig, dpi)
    plt.close(fig)
    return pb

def make_estimate_pixbuf(session, avg_rate, current_pct, rolling_rate, dpi=150):
    pts  = session['points']
    xs   = [(p['ts'] - pts[0]['ts']) / 3600 for p in pts]
    ys   = [p['val'] for p in pts]
    now_h = xs[-1]

    fig, ax = plt.subplots(figsize=(6.5, 2.8))
    _style_ax(ax, fig)

    proj_end = now_h + (current_pct / avg_rate) if avg_rate > 0 else now_h + 2
    ax.set_xlim(-0.05, max(xs[-1] + 0.5, proj_end + 0.3))
    ax.set_ylim(-2, 105)

    _draw_discharge_line(ax, pts, xs, ys, ACTIVE)

    if avg_rate > 0:
        pxs = np.linspace(now_h, proj_end, 60)
        pys = [max(0, current_pct - avg_rate * (x - now_h)) for x in pxs]
        ax.plot(pxs, pys, color=SUBTEXT, linewidth=1.5, linestyle='--',
                label='Session avg est.', alpha=0.7, zorder=6)

    if rolling_rate and rolling_rate > 0:
        rend = now_h + (current_pct / rolling_rate)
        rxs  = np.linspace(now_h, rend, 60)
        rys  = [max(0, current_pct - rolling_rate * (x - now_h)) for x in rxs]
        ax.plot(rxs, rys, color=FAIR, linewidth=2, linestyle=':',
                label='Current load est.', alpha=0.9, zorder=6)

    ax.axvspan(now_h, ax.get_xlim()[1], alpha=0.04, color='white')
    ax.legend(fontsize=8, facecolor=BG2, edgecolor=BG3,
              labelcolor=SUBTEXT, loc='upper right')
    _smart_xticks(ax, ax.get_xlim()[1])
    plt.tight_layout(pad=0.4)
    pb = _fig_to_pixbuf(fig, dpi)
    plt.close(fig)
    return pb

def make_sparkline_pixbuf(session, dpi=120):
    pts = session['points']
    xs  = [(p['ts'] - pts[0]['ts']) / 3600 for p in pts]
    ys  = [p['val'] for p in pts]
    color = RATING_COLORS.get(
        'active' if session.get('active') else session['usage_rating'], GOOD)

    fig, ax = plt.subplots(figsize=(2.8, 0.75))
    fig.patch.set_alpha(0)
    ax.set_facecolor('none')
    ax.fill_between(xs, ys, alpha=0.18, color=color)
    ax.plot(xs, ys, color=color, linewidth=1.8, solid_capstyle='round')
    ax.plot(xs[-1], ys[-1], 'o', color=color, markersize=4, zorder=5)
    ax.set_xlim(min(xs) - 0.03, max(xs) + 0.03)
    ax.set_ylim(max(0, min(ys) - 8), min(105, max(ys) + 8))
    ax.axis('off')
    plt.tight_layout(pad=0)

    buf = io.BytesIO()
    fig.savefig(buf, format='png', dpi=dpi, bbox_inches='tight',
                transparent=True, pad_inches=0)
    buf.seek(0)
    plt.close(fig)
    loader = GdkPixbuf.PixbufLoader.new_with_type('png')
    loader.write(buf.read())
    loader.close()
    return loader.get_pixbuf()


# ═══════════════════════════════════════════════════════════════════════════════
# UI HELPERS
# ═══════════════════════════════════════════════════════════════════════════════

def _label(text, css_class=None, markup=False, xalign=0.0):
    if markup:
        lbl = Gtk.Label()
        lbl.set_markup(text)
    else:
        lbl = Gtk.Label(label=text)
    lbl.set_xalign(xalign)
    if css_class:
        lbl.get_style_context().add_class(css_class)
    return lbl

def _box(orient=Gtk.Orientation.VERTICAL, spacing=0):
    return Gtk.Box(orientation=orient, spacing=spacing)

def _scrolled(child=None, hpolicy=Gtk.PolicyType.NEVER,
              vpolicy=Gtk.PolicyType.AUTOMATIC):
    sw = Gtk.ScrolledWindow()
    sw.set_policy(hpolicy, vpolicy)
    if child is not None:
        sw.add(child)
    return sw

def _separator(orient=Gtk.Orientation.HORIZONTAL):
    sep = Gtk.Separator(orientation=orient)
    sep.get_style_context().add_class('separator')
    return sep

def _stat_card(val_text, lbl_text, color=None):
    card = _box(spacing=4)
    card.get_style_context().add_class('stat-card')
    val = _label(val_text, 'stat-card-val')
    if color:
        _set_color(val, color)
    card.pack_start(val, False, False, 0)
    card.pack_start(_label(lbl_text, 'stat-card-lbl'), False, False, 0)
    return card, val

def _hex_to_rgba(hex_color):
    h = hex_color.lstrip('#')
    r, g, b = (int(h[i:i+2], 16) / 255 for i in (0, 2, 4))
    return r, g, b, 1.0

def _set_color(widget, hex_color):
    """Set widget foreground color using a per-widget CSS provider."""
    css = f'* {{ color: {hex_color}; }}'.encode('utf-8')
    provider = Gtk.CssProvider()
    provider.load_from_data(css)
    widget.get_style_context().add_provider(
        provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

def _pixbuf_image(pb, width=None):
    img = Gtk.Image.new_from_pixbuf(pb)
    if width and pb:
        h = int(pb.get_height() * width / pb.get_width())
        scaled = pb.scale_simple(width, h, GdkPixbuf.InterpType.BILINEAR)
        img.set_from_pixbuf(scaled)
    return img


# ═══════════════════════════════════════════════════════════════════════════════
# MAIN APPLICATION WINDOW
# ═══════════════════════════════════════════════════════════════════════════════

class BatteryLensApp(Gtk.Application):
    def __init__(self):
        super().__init__(application_id='io.github.filoviridae.batterylens',
                         flags=Gio.ApplicationFlags.FLAGS_NONE)
        self.connect('activate', self.on_activate)

    def on_activate(self, app):
        try:
            win = BatteryLensWindow(application=app)
            win.show_all()
        except Exception:
            import traceback
            traceback.print_exc()
            dialog = Gtk.MessageDialog(
                flags=0,
                message_type=Gtk.MessageType.ERROR,
                buttons=Gtk.ButtonsType.OK,
                text='BatteryLens failed to start')
            import traceback as tb
            dialog.format_secondary_text(tb.format_exc()[-800:])
            dialog.run()
            dialog.destroy()
            self.destroy()
            Gtk.main_quit()


class BatteryLensWindow(Gtk.Window):
    def __init__(self):
        super().__init__(title='BatteryLens')
        self.set_default_size(1100, 720)
        self.set_size_request(800, 500)
        self.connect('destroy', Gtk.main_quit)

        # Set window icon for taskbar
        if os.path.exists(ICON_PATH):
            try:
                pb = GdkPixbuf.Pixbuf.new_from_file(ICON_PATH)
                self.set_icon(pb)
            except Exception:
                pass
        self.set_wmclass('batterylens', 'BatteryLens')

        # App state
        self._sessions     = []
        self._hidden_ts    = load_hidden_ts()
        self._hidden_idxs  = set()
        self._selected_idx = None
        self._bat_info     = None
        self._dpi = int(min(2.2, self.get_scale_factor() or 1) * 120)

        self._build_ui()
        self._apply_css()
        self._load_data()

        # Auto-refresh every 60s when there's an active session
        GLib.timeout_add_seconds(60, self._auto_refresh)

    # ── CSS ───────────────────────────────────────────────────────────────────

    def _apply_css(self):
        provider = Gtk.CssProvider()
        provider.load_from_data(CSS.encode('utf-8'))
        Gtk.StyleContext.add_provider_for_screen(
            Gdk.Screen.get_default(), provider,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

    # ── UI construction ───────────────────────────────────────────────────────

    def _build_ui(self):
        # Root: horizontal paned (sidebar | main)
        self._paned = Gtk.Paned(orientation=Gtk.Orientation.HORIZONTAL)
        self._paned.set_position(300)
        self.add(self._paned)

        self._paned.pack1(self._build_sidebar(), resize=False, shrink=False)
        self._paned.pack2(self._build_main(),    resize=True,  shrink=False)

    # ── SIDEBAR ───────────────────────────────────────────────────────────────

    def _build_sidebar(self):
        sidebar = _box(spacing=0)
        sidebar.set_name('sidebar')
        sidebar.set_size_request(280, -1)

        # Header
        hdr = _box(spacing=4)
        hdr.set_name('sidebar-header')
        hdr.set_margin_bottom(0)

        # App icon + name row
        name_row = _box(Gtk.Orientation.HORIZONTAL, 8)
        if os.path.exists(ICON_PATH):
            try:
                pb = GdkPixbuf.Pixbuf.new_from_file_at_size(ICON_PATH, 28, 28)
                icon_img = Gtk.Image.new_from_pixbuf(pb)
                name_row.pack_start(icon_img, False, False, 0)
            except Exception:
                pass
        self._app_name_lbl = _label('BatteryLens', 'app-name')
        name_row.pack_start(self._app_name_lbl, False, False, 0)

        # Update button (top right)
        update_btn = Gtk.Button(label='⟳ Check for updates')
        update_btn.set_name('update-btn')
        update_btn.connect('clicked', self._on_check_update)
        update_btn.set_halign(Gtk.Align.END)
        update_btn.set_hexpand(True)
        name_row.pack_end(update_btn, False, False, 0)

        self._header_sub = _label('Loading…', 'header-sub')
        hdr.pack_start(name_row, False, False, 0)
        hdr.pack_start(self._header_sub, False, False, 0)
        sidebar.pack_start(hdr, False, False, 0)

        # Stats row
        stats_box = _box(Gtk.Orientation.HORIZONTAL, 0)
        stats_box.set_margin_start(8)
        stats_box.set_margin_end(8)
        stats_box.set_margin_top(10)
        stats_box.set_margin_bottom(6)

        self._stat_avg      = self._small_stat('—', 'Avg Life')
        self._stat_best     = self._small_stat('—', 'Best')
        self._stat_sessions = self._small_stat('0', 'Sessions')

        for s in [self._stat_avg, self._stat_best, self._stat_sessions]:
            stats_box.pack_start(s, True, True, 0)
        sidebar.pack_start(stats_box, False, False, 0)
        sidebar.pack_start(_separator(), False, False, 0)

        # Section label
        sec = _label('Charge Sessions', 'section-header')
        sidebar.pack_start(sec, False, False, 0)

        # Session list
        self._session_list = Gtk.ListBox()
        self._session_list.set_selection_mode(Gtk.SelectionMode.NONE)
        self._session_list.set_activate_on_single_click(True)
        self._session_list.connect('row-activated', self._on_session_activated)
        self._session_list.set_margin_top(4)

        sw = _scrolled(self._session_list)
        sw.set_name('session-list-scroll')
        sw.set_vexpand(True)
        sidebar.pack_start(sw, True, True, 0)

        # Restore button in dark footer
        restore_footer = _box(spacing=0)
        restore_footer.set_name('restore-footer')
        self._restore_btn = Gtk.Button(label='↩ Restore hidden session')
        self._restore_btn.set_name('restore-btn')
        self._restore_btn.connect('clicked', self._on_restore_clicked)
        self._restore_btn.set_no_show_all(True)
        self._restore_btn.hide()
        restore_footer.pack_start(self._restore_btn, True, True, 0)
        sidebar.pack_end(restore_footer, False, False, 0)

        return sidebar

    def _small_stat(self, val, lbl):
        box = _box(spacing=1)
        box.get_style_context().add_class('stat-box')
        box.set_margin_start(3)
        box.set_margin_end(3)
        val_lbl = _label(val, 'stat-val', xalign=0.5)
        val_lbl.set_halign(Gtk.Align.CENTER)
        lbl_lbl = _label(lbl, 'stat-lbl', xalign=0.5)
        lbl_lbl.set_halign(Gtk.Align.CENTER)
        box.pack_start(val_lbl, False, False, 0)
        box.pack_start(lbl_lbl, False, False, 0)
        box._val_lbl = val_lbl
        return box

    # ── MAIN PANEL ────────────────────────────────────────────────────────────

    def _build_main(self):
        main = _box(spacing=0)
        main.set_name('main-panel')

        # Tab bar
        tab_bar = _box(Gtk.Orientation.HORIZONTAL, 0)
        tab_bar.set_name('tab-bar')
        self._tab_overview = Gtk.Button(label='Overview')
        self._tab_overview.get_style_context().add_class('tab-btn')
        self._tab_overview.get_style_context().add_class('tab-btn-active')
        self._tab_overview.connect('clicked', lambda _: self._switch_tab('overview'))

        tab_bar.pack_start(self._tab_overview, False, False, 0)
        main.pack_start(tab_bar, False, False, 0)
        main.pack_start(_separator(), False, False, 0)

        # Stack for content
        self._stack = Gtk.Stack()
        self._stack.set_transition_type(Gtk.StackTransitionType.NONE)
        self._stack.set_vexpand(True)
        self._stack.set_hexpand(True)

        self._stack.add_named(self._build_overview_page(),  'overview')
        self._stack.add_named(self._build_detail_page(),    'detail')
        self._stack.add_named(self._build_empty_page(),     'empty')

        self._stack.set_visible_child_name('empty')
        main.pack_start(self._stack, True, True, 0)

        return main

    # ── OVERVIEW PAGE ─────────────────────────────────────────────────────────

    def _build_overview_page(self):
        sw = _scrolled()
        box = _box(spacing=0)
        box.set_margin_start(24)
        box.set_margin_end(24)
        box.set_margin_top(20)
        box.set_margin_bottom(20)

        # Header row with refresh button
        hdr_row = _box(Gtk.Orientation.HORIZONTAL, 0)
        hdr_lbl = _label('Overview', css_class=None)
        hdr_lbl.set_markup('<span size="x-large" weight="heavy">Overview</span>')
        hdr_lbl.set_xalign(0)
        hdr_row.pack_start(hdr_lbl, True, True, 0)
        refresh_btn = Gtk.Button(label='↻ Refresh')
        refresh_btn.set_name('refresh-btn')
        refresh_btn.connect('clicked', lambda _: self._load_data())
        refresh_btn.set_valign(Gtk.Align.CENTER)
        hdr_row.pack_end(refresh_btn, False, False, 0)

        sub_lbl = _label('All charge sessions at a glance', css_class=None)
        sub_lbl.set_xalign(0)
        _set_color(sub_lbl, SUBTEXT)
        box.pack_start(hdr_row, False, False, 0)
        box.pack_start(sub_lbl, False, False, 4)
        box.pack_start(_box(spacing=0), False, False, 8)

        # Battery strip
        self._bat_strip = self._build_bat_strip()
        box.pack_start(self._bat_strip, False, False, 4)

        # Overview chart card
        self._overview_chart_card = _box(spacing=4)
        self._overview_chart_card.get_style_context().add_class('chart-card')
        self._overview_chart_lbl = _label('Recent sessions — full-charge equivalent (active)',
                                          'chart-label')
        self._overview_chart_lbl.set_margin_bottom(6)
        self._overview_chart_image = Gtk.Image()
        self._overview_chart_card.pack_start(self._overview_chart_lbl, False, False, 0)
        self._overview_chart_card.pack_start(self._overview_chart_image, False, False, 0)
        box.pack_start(self._overview_chart_card, False, False, 4)
        self._overview_chart_card.hide()

        # Stats grid
        self._ov_stat_grid = Gtk.Grid()
        self._ov_stat_grid.set_column_homogeneous(True)
        self._ov_stat_grid.set_row_spacing(0)
        self._ov_stat_grid.set_column_spacing(0)
        self._ov_stat_grid.set_margin_top(4)
        self._ov_stat_avg = self._make_stat_card('—', 'Avg life (active)')
        self._ov_stat_best = self._make_stat_card('—', 'Best session')
        self._ov_stat_worst = self._make_stat_card('—', 'Worst session')
        self._ov_stat_grid.attach(self._ov_stat_avg,   0, 0, 1, 1)
        self._ov_stat_grid.attach(self._ov_stat_best,  1, 0, 1, 1)
        self._ov_stat_grid.attach(self._ov_stat_worst, 2, 0, 1, 1)
        box.pack_start(self._ov_stat_grid, False, False, 0)

        # Estimate panel (shown when only active session visible)
        self._estimate_panel = self._build_estimate_panel()
        self._estimate_panel.set_no_show_all(True)
        self._estimate_panel.hide()
        box.pack_start(self._estimate_panel, False, False, 4)

        # No-data state
        self._no_data_box = self._build_no_data()
        self._no_data_box.set_no_show_all(True)
        self._no_data_box.hide()
        box.pack_start(self._no_data_box, True, True, 0)

        sw.add(box)
        return sw

    def _build_bat_strip(self):
        strip = _box(Gtk.Orientation.HORIZONTAL, 12)
        strip.get_style_context().add_class('bat-strip')
        strip.set_margin_bottom(4)

        left = _box(spacing=2)
        self._bat_model_lbl  = _label('Battery', 'bat-model')
        self._bat_detail_lbl = _label('', 'bat-detail')
        left.pack_start(self._bat_model_lbl,  False, False, 0)
        left.pack_start(self._bat_detail_lbl, False, False, 0)

        self._bat_pct_lbl = _label('—%', 'bat-pct')
        self._bat_pct_lbl.set_halign(Gtk.Align.END)

        strip.pack_start(left, True, True, 0)
        strip.pack_end(self._bat_pct_lbl, False, False, 0)
        return strip

    def _build_estimate_panel(self):
        box = _box(spacing=8)

        # Stats row
        grid = Gtk.Grid()
        grid.set_column_homogeneous(True)
        self._est_current_card  = self._make_stat_card('—', 'Battery now', ACTIVE)
        self._est_rolling_card  = self._make_stat_card('—', 'Est. remaining (current load)', ACTIVE)
        self._est_avg_card      = self._make_stat_card('—', 'Est. remaining (session avg)', SUBTEXT)
        grid.attach(self._est_rolling_card,  0, 0, 1, 1)
        grid.attach(self._est_avg_card,      1, 0, 1, 1)
        grid.attach(self._est_current_card,  2, 0, 1, 1)
        box.pack_start(grid, False, False, 0)

        # Drain rates line
        self._est_rates_lbl = _label('', 'estimate-rate')
        box.pack_start(self._est_rates_lbl, False, False, 0)

        # Chart
        self._est_chart_card = _box(spacing=4)
        self._est_chart_card.get_style_context().add_class('chart-card')
        self._est_chart_lbl   = _label('Battery projection', 'chart-label')
        self._est_chart_image = Gtk.Image()
        self._est_chart_card.pack_start(self._est_chart_lbl,  False, False, 0)
        self._est_chart_card.pack_start(self._est_chart_image, False, False, 0)
        box.pack_start(self._est_chart_card, False, False, 0)

        return box

    def _build_no_data(self):
        box = _box(spacing=8)
        box.set_valign(Gtk.Align.CENTER)
        box.set_halign(Gtk.Align.CENTER)
        box.set_margin_top(60)
        lbl1 = _label('No sessions recorded yet', 'empty-title', xalign=0.5)
        lbl1.set_halign(Gtk.Align.CENTER)
        lbl2 = _label('Unplug your laptop and use it on battery.\nData will appear after your first session.',
                       'empty-sub', xalign=0.5)
        lbl2.set_halign(Gtk.Align.CENTER)
        lbl2.set_justify(Gtk.Justification.CENTER)
        box.pack_start(lbl1, False, False, 0)
        box.pack_start(lbl2, False, False, 0)
        return box

    # ── DETAIL PAGE ───────────────────────────────────────────────────────────

    def _build_detail_page(self):
        box = _box(spacing=0)

        # Header
        self._detail_header = _box(Gtk.Orientation.HORIZONTAL, 16)
        self._detail_header.set_name('detail-header')

        icon_box = _box(spacing=0)
        self._detail_icon = _label('⚡', xalign=0.5)
        self._detail_icon.set_halign(Gtk.Align.CENTER)
        icon_box.pack_start(self._detail_icon, False, False, 0)

        text_box = _box(spacing=2)
        self._detail_title    = Gtk.Label()
        self._detail_title.set_name('detail-title')
        self._detail_title.set_xalign(0)
        self._detail_subtitle = _label('', css_class=None)
        self._detail_subtitle.set_name('detail-subtitle')
        text_box.pack_start(self._detail_title,    False, False, 0)
        text_box.pack_start(self._detail_subtitle, False, False, 0)

        self._detail_header.pack_start(icon_box, False, False, 0)
        self._detail_header.pack_start(text_box, True, True, 0)
        box.pack_start(self._detail_header, False, False, 0)

        # Scrollable body
        sw = _scrolled()
        body = _box(spacing=0)
        body.set_margin_start(24)
        body.set_margin_end(24)
        body.set_margin_top(16)
        body.set_margin_bottom(20)

        # Sleep note
        self._sleep_note = _label('', 'sleep-note')
        self._sleep_note.set_line_wrap(True)
        self._sleep_note.set_xalign(0)
        self._sleep_note_box = _box(spacing=0)
        self._sleep_note_box.set_margin_bottom(8)
        self._sleep_note_box.pack_start(self._sleep_note, False, False, 0)
        self._sleep_note_box.set_no_show_all(True)
        body.pack_start(self._sleep_note_box, False, False, 0)

        # Stats grid
        self._detail_grid = Gtk.Grid()
        self._detail_grid.set_column_homogeneous(True)
        self._detail_equiv_card = self._make_stat_card('—', 'Full-charge equiv. (active)')
        self._detail_drain_card = self._make_stat_card('—', 'Battery drained')
        self._detail_rating_card = self._make_stat_card('—', 'Rating')
        self._detail_grid.attach(self._detail_equiv_card,  0, 0, 1, 1)
        self._detail_grid.attach(self._detail_drain_card,  1, 0, 1, 1)
        self._detail_grid.attach(self._detail_rating_card, 2, 0, 1, 1)
        body.pack_start(self._detail_grid, False, False, 4)

        # Battery bar
        batt_card = _box(spacing=6)
        batt_card.get_style_context().add_class('chart-card')
        batt_card.set_margin_top(8)
        self._batt_bar_lbl = _label('Battery used this session', 'chart-label')
        self._batt_bar_outer = Gtk.DrawingArea()
        self._batt_bar_outer.set_size_request(-1, 24)
        self._batt_bar_outer.connect('draw', self._draw_batt_bar)
        self._batt_bar_labels = _box(Gtk.Orientation.HORIZONTAL, 0)
        self._batt_start_lbl = _label('', css_class=None)
        _set_color(self._batt_start_lbl, SUBTEXT)
        self._batt_end_lbl   = _label('', css_class=None)
        self._batt_end_lbl.set_halign(Gtk.Align.END)
        _set_color(self._batt_end_lbl, SUBTEXT)
        self._batt_bar_labels.pack_start(self._batt_start_lbl, True, True, 0)
        self._batt_bar_labels.pack_end(self._batt_end_lbl, False, False, 0)
        batt_card.pack_start(self._batt_bar_lbl,    False, False, 0)
        batt_card.pack_start(self._batt_bar_outer,  False, False, 0)
        batt_card.pack_start(self._batt_bar_labels, False, False, 2)
        body.pack_start(batt_card, False, False, 4)

        # Chart
        chart_card = _box(spacing=4)
        chart_card.get_style_context().add_class('chart-card')
        chart_card.set_margin_top(4)
        self._detail_chart_lbl   = _label('Battery level over time', 'chart-label')
        self._detail_chart_image = Gtk.Image()
        chart_card.pack_start(self._detail_chart_lbl,   False, False, 0)
        chart_card.pack_start(self._detail_chart_image, False, False, 0)
        body.pack_start(chart_card, False, False, 4)

        # Points recorded
        self._detail_points_card = self._make_stat_card('—', 'Data points recorded')
        self._detail_points_card.set_margin_top(4)
        body.pack_start(self._detail_points_card, False, False, 0)

        sw.add(body)
        box.pack_start(sw, True, True, 0)
        return box

    # ── EMPTY PAGE ────────────────────────────────────────────────────────────

    def _build_empty_page(self):
        box = _box(spacing=12)
        box.set_valign(Gtk.Align.CENTER)
        box.set_halign(Gtk.Align.CENTER)
        icon = _label('🔋', xalign=0.5)
        icon.set_markup('<span size="xx-large">🔋</span>')
        icon.set_halign(Gtk.Align.CENTER)
        lbl1 = _label('Select a session', 'empty-title', xalign=0.5)
        lbl1.set_halign(Gtk.Align.CENTER)
        lbl2 = _label('Tap any charge session to see details', 'empty-sub', xalign=0.5)
        lbl2.set_halign(Gtk.Align.CENTER)
        box.pack_start(icon, False, False, 0)
        box.pack_start(lbl1, False, False, 0)
        box.pack_start(lbl2, False, False, 0)
        return box

    # ── Reusable stat card widget ─────────────────────────────────────────────

    def _make_stat_card(self, val, lbl, color=None):
        card = _box(spacing=2)
        card.get_style_context().add_class('stat-card')
        val_lbl = _label(val, 'stat-card-val')
        if color:
            _set_color(val_lbl, color)
        lbl_lbl = _label(lbl, 'stat-card-lbl')
        card.pack_start(val_lbl, False, False, 0)
        card.pack_start(lbl_lbl, False, False, 0)
        card._val_lbl = val_lbl
        card._lbl_lbl = lbl_lbl
        return card

    # ── Battery bar drawing ───────────────────────────────────────────────────

    def _draw_batt_bar(self, widget, cr):
        w = widget.get_allocated_width()
        h = widget.get_allocated_height()
        r = h / 2
        start = getattr(self, '_batt_start_pct', 100)
        end   = getattr(self, '_batt_end_pct', 80)
        color = getattr(self, '_batt_color', ACTIVE)

        # Background track
        cr.set_source_rgb(*[int(BG3.lstrip('#')[i:i+2], 16)/255 for i in (0,2,4)])
        cr.arc(r, r, r, math.pi/2, 3*math.pi/2)
        cr.arc(w-r, r, r, -math.pi/2, math.pi/2)
        cr.close_path()
        cr.fill()

        # End fill (lighter, showing start level)
        start_w = w * start / 100
        rgba = [int(color.lstrip('#')[i:i+2], 16)/255 for i in (0,2,4)]
        cr.set_source_rgba(*rgba, 0.35)
        cr.arc(r, r, r, math.pi/2, 3*math.pi/2)
        end_r = min(r, start_w - r) if start_w > r else 0
        if start_w > 0:
            cr.rectangle(r, 0, start_w - r, h)
            if start_w >= w - r:
                cr.arc(w-r, r, r, -math.pi/2, math.pi/2)
            cr.close_path()
            cr.fill()

        # End fill (solid, showing end level)
        end_w = w * end / 100
        cr.set_source_rgb(*rgba)
        if end_w > 0:
            cr.arc(r, r, r, math.pi/2, 3*math.pi/2)
            cr.rectangle(r, 0, max(0, end_w - r), h)
            if end_w >= w - r:
                cr.arc(w-r, r, r, -math.pi/2, math.pi/2)
            cr.close_path()
            cr.fill()

    # ═══════════════════════════════════════════════════════════════════════════
    # DATA LOADING & UI REFRESH
    # ═══════════════════════════════════════════════════════════════════════════

    def _load_data(self):
        """Load sessions and battery info, then refresh UI."""
        self._sessions    = _read_upower_history() or []
        self._bat_info    = get_battery_info()
        self._hidden_idxs = resolve_hidden_idxs(self._sessions, self._hidden_ts)
        self._refresh_sidebar()
        self._refresh_overview()
        # If the selected session is the active one, refresh its detail view too
        if self._selected_idx is not None:
            s = self._sessions[self._selected_idx] if self._selected_idx < len(self._sessions) else None
            if s and s.get('active'):
                self._show_session_detail(self._selected_idx)
        return True  # keep GLib.timeout running

    def _auto_refresh(self):
        """Called every 60s — only reloads if there's an active session."""
        has_active = any(s.get('active') for s in self._sessions)
        if has_active:
            self._load_data()
        return True  # keep timer alive

    def _visible_sessions(self):
        return [s for i, s in enumerate(self._sessions)
                if i not in self._hidden_idxs]

    def _refresh_sidebar(self):
        visible = self._visible_sessions()
        completed = [s for s in visible if not s.get('active')]

        # Update stats
        avg_h = (sum(s['full_equiv_h'] for s in completed) / len(completed)
                 if completed else 0)
        best  = max((s['full_equiv_h'] for s in completed), default=0)

        self._stat_avg._val_lbl.set_text(fmt_duration(avg_h) if avg_h else '—')
        self._stat_best._val_lbl.set_text(fmt_duration(best) if best else '—')
        self._stat_sessions._val_lbl.set_text(str(len(completed)))

        sub = (f'{len(completed)} sessions tracked' if completed
               else 'No history yet')
        self._header_sub.set_text(sub)

        # Rebuild session list
        for row in self._session_list.get_children():
            self._session_list.remove(row)

        if not visible:
            row = Gtk.ListBoxRow()
            row.set_activatable(False)
            lbl = _label(
                'No sessions visible' if self._sessions else 'No history yet',
                'empty-sub', xalign=0.5)
            lbl.set_margin_top(24)
            lbl.set_margin_bottom(24)
            lbl.set_halign(Gtk.Align.CENTER)
            row.add(lbl)
            self._session_list.add(row)
            self._session_list.show_all()
            self._restore_btn.show()
            return

        # Group by date
        groups = {}
        for s in visible:
            key = s['start'].strftime('%b %-d, %Y')
            groups.setdefault(key, []).append(s)

        first = True
        for date_str, sessions in groups.items():
            # Date header
            hdr_row = Gtk.ListBoxRow()
            hdr_row.set_activatable(False)
            hdr_lbl = _label(date_str, 'section-header')
            hdr_lbl.set_margin_top(8 if first else 4)
            hdr_row.add(hdr_lbl)
            self._session_list.add(hdr_row)
            first = False

            for s in sessions:
                idx = self._sessions.index(s)
                row = self._build_session_row(s, idx)
                self._session_list.add(row)

        self._session_list.show_all()

        # Restore button
        hidden = [s for i, s in enumerate(self._sessions)
                  if i in self._hidden_idxs]
        if hidden:
            n = len(hidden)
            self._restore_btn.set_label(
                f'↩ Restore hidden session{"s" if n > 1 else ""} ({n})')
            self._restore_btn.show()
        else:
            self._restore_btn.hide()

    def _build_session_row(self, s, idx):
        row = Gtk.ListBoxRow()
        row._session_idx = idx

        outer = _box(spacing=0)
        color = RATING_COLORS.get(
            'active' if s.get('active') else s['usage_rating'], GOOD)

        # Active badge
        if s.get('active'):
            badge = _label('● Currently discharging', 'active-badge')
            outer.pack_start(badge, False, False, 0)

        inner = _box(Gtk.Orientation.HORIZONTAL, 8)
        inner.get_style_context().add_class('session-row')

        # Colour dot
        dot = Gtk.DrawingArea()
        dot.set_size_request(8, 8)
        dot.set_valign(Gtk.Align.CENTER)
        r, g, b, _ = _hex_to_rgba(color)
        dot.connect('draw', lambda w, cr, r=r, g=g, b=b: (
            cr.set_source_rgb(r, g, b),
            cr.arc(4, 4, 4, 0, 2*math.pi),
            cr.fill()
        ))
        inner.pack_start(dot, False, False, 0)

        # Date/time
        left = _box(spacing=1)
        time_str = s['start'].strftime('%-I:%M %p') if s.get('active') else \
                   s['start'].strftime('%-I:%M %p')
        date_lbl = _label('Now' if s.get('active') else time_str, 'session-date')
        time_lbl = _label(fmt_time_range(s['start'], s['end']), 'session-time')
        left.pack_start(date_lbl, False, False, 0)
        left.pack_start(time_lbl, False, False, 0)
        inner.pack_start(left, True, True, 0)

        # Sparkline
        try:
            pb = make_sparkline_pixbuf(s)
            if pb:
                h = 30
                w = int(pb.get_width() * h / pb.get_height())
                pb_scaled = pb.scale_simple(w, h, GdkPixbuf.InterpType.BILINEAR)
                spark_img = Gtk.Image.new_from_pixbuf(pb_scaled)
                inner.pack_start(spark_img, False, False, 0)
        except Exception:
            pass

        # Duration
        right = _box(spacing=1)
        right.set_halign(Gtk.Align.END)
        dur_lbl = _label(fmt_duration(s['duration_h']), 'session-duration')
        _set_color(dur_lbl, color)
        rng_lbl = _label(f"{s['start_pct']}%→{s['end_pct']}%", 'session-range')
        right.pack_start(dur_lbl, False, False, 0)
        right.pack_start(rng_lbl, False, False, 0)
        inner.pack_end(right, False, False, 0)

        # Hide button
        hide_btn = Gtk.Button(label='✕')
        hide_btn.set_relief(Gtk.ReliefStyle.NONE)
        hide_btn.get_style_context().add_class('flat')
        hide_btn.set_valign(Gtk.Align.CENTER)
        _set_color(hide_btn.get_child(), SUBTEXT)
        hide_btn.connect('clicked', self._on_hide_session, idx)
        inner.pack_end(hide_btn, False, False, 0)

        outer.pack_start(inner, True, True, 0)
        row.add(outer)
        return row

    def _refresh_overview(self):
        visible = self._visible_sessions()
        completed = [s for s in visible if not s.get('active')]
        active_sessions = [s for s in visible if s.get('active')]
        active_only = (len(visible) == 1 and len(active_sessions) == 1)

        # Battery strip
        if self._bat_info:
            b = self._bat_info
            self._bat_model_lbl.set_text(b.get('model', 'Battery'))
            detail_parts = [b.get('status', '')]
            if b.get('technology'): detail_parts.append(b['technology'])
            if b.get('cycle_count'): detail_parts.append(f"{b['cycle_count']} cycles")
            self._bat_detail_lbl.set_text(' · '.join(p for p in detail_parts if p))
            self._bat_pct_lbl.set_text(f"{b.get('capacity', '?')}%")
            self._bat_strip.show()
        else:
            self._bat_strip.hide()

        # No data
        if not visible:
            self._no_data_box.show()
            self._overview_chart_card.hide()
            self._ov_stat_grid.hide()
            self._estimate_panel.hide()
            return

        self._no_data_box.hide()

        # Overview bar chart (show when there are completed sessions)
        if completed:
            pb = make_overview_pixbuf(visible, self._dpi)
            if pb:
                w = 680
                h = int(pb.get_height() * w / pb.get_width())
                scaled = pb.scale_simple(w, h, GdkPixbuf.InterpType.BILINEAR)
                self._overview_chart_image.set_from_pixbuf(scaled)
                self._overview_chart_card.show_all()
        else:
            self._overview_chart_card.hide()

        # Stats
        avg_h   = (sum(s['full_equiv_h'] for s in completed) / len(completed)
                   if completed else 0)
        best_s  = max(completed, key=lambda x: x['full_equiv_h'], default=None)
        worst_s = min(completed, key=lambda x: x['full_equiv_h'], default=None)

        self._ov_stat_avg._val_lbl.set_text(fmt_duration(avg_h) if avg_h else '—')
        self._ov_stat_best._val_lbl.set_text(
            fmt_duration(best_s['full_equiv_h']) if best_s else '—')
        self._ov_stat_worst._val_lbl.set_text(
            fmt_duration(worst_s['full_equiv_h']) if worst_s else '—')
        self._ov_stat_grid.show()

        # Estimate panel — show whenever there's an active session
        if active_sessions:
            self._refresh_estimate(active_sessions[0])
            self._estimate_panel.show_all()
        else:
            self._estimate_panel.hide()

    def _refresh_estimate(self, s):
        pts = s['points']
        if len(pts) < 2:
            return
        current_pct = pts[-1]['val']
        total_drain = pts[0]['val'] - pts[-1]['val']

        active_s = sum(
            pts[i]['ts'] - pts[i-1]['ts']
            for i in range(1, len(pts))
            if pts[i]['ts'] - pts[i-1]['ts'] <= SLEEP_GAP_THRESHOLD_S
        )
        active_h = active_s / 3600
        avg_rate = total_drain / active_h if active_h > 0 else 0

        cutoff = pts[-1]['ts'] - 1200
        recent = [p for p in pts if p['ts'] >= cutoff]
        if len(recent) >= 2:
            roll_drain = recent[0]['val'] - recent[-1]['val']
            roll_h = (recent[-1]['ts'] - recent[0]['ts']) / 3600
            rolling_rate = roll_drain / roll_h if roll_h > 0 else avg_rate
        else:
            rolling_rate = avg_rate

        avg_rate     = max(0.5, min(50, avg_rate))     if avg_rate > 0     else 0
        rolling_rate = max(0.5, min(50, rolling_rate)) if rolling_rate > 0 else 0

        rem_avg     = current_pct / avg_rate     if avg_rate > 0     else None
        rem_rolling = current_pct / rolling_rate if rolling_rate > 0 else None

        self._est_current_card._val_lbl.set_text(f'{int(current_pct)}%')
        self._est_rolling_card._val_lbl.set_text(
            fmt_duration(rem_rolling) if rem_rolling else '—')
        self._est_avg_card._val_lbl.set_text(
            fmt_duration(rem_avg) if rem_avg else '—')
        self._est_rates_lbl.set_text(
            f'Current drain: {rolling_rate:.1f}%/h  ·  '
            f'Session avg: {avg_rate:.1f}%/h  ·  '
            f'Based on last {len(recent)} readings')

        pb = make_estimate_pixbuf(s, avg_rate, current_pct, rolling_rate, self._dpi)
        if pb:
            w = 680
            h = int(pb.get_height() * w / pb.get_width())
            scaled = pb.scale_simple(w, h, GdkPixbuf.InterpType.BILINEAR)
            self._est_chart_image.set_from_pixbuf(scaled)

    def _show_session_detail(self, idx):
        if idx < 0 or idx >= len(self._sessions):
            return
        s = self._sessions[idx]
        self._selected_idx = idx
        color = RATING_COLORS.get(
            'active' if s.get('active') else s['usage_rating'], GOOD)

        # Header
        self._detail_title.set_markup(
            f'<span color="{color}" weight="heavy" size="x-large">'
            f'{fmt_duration(s["duration_h"])}</span>')

        # Date string
        if s['start'].date() != s['end'].date():
            date_str = (s['start'].strftime('%b %-d') + ' – ' +
                        s['end'].strftime('%b %-d, %Y'))
        else:
            date_str = s['start'].strftime('%A, %B %-d, %Y')
        self._detail_subtitle.set_text(
            f'{date_str} · {fmt_time_range(s["start"], s["end"])}')

        # Sleep note
        sleep_count = len(s.get('sleep_gaps', []))
        active_h = s.get('active_h', s['duration_h'])
        if sleep_count > 0:
            diff_h = s['duration_h'] - active_h
            note = (f'{sleep_count} sleep period{"s" if sleep_count > 1 else ""} '
                    f'detected.  Wall-clock: {fmt_duration(s["duration_h"])}  ·  '
                    f'Active: {fmt_duration(active_h)}.  '
                    f'Full-charge equivalent calculated from active time only.')
            self._sleep_note.set_text(note)
            self._sleep_note_box.show()
        else:
            self._sleep_note_box.hide()

        # Stat cards
        self._detail_equiv_card._val_lbl.set_text(fmt_duration(s['full_equiv_h']))
        self._detail_drain_card._val_lbl.set_text(f'{s["drain_pct"]}%')
        rating_text = 'Active' if s.get('active') else s['usage_rating'].title()
        self._detail_rating_card._val_lbl.set_text(rating_text)
        _set_color(self._detail_rating_card._val_lbl, color)

        # Battery bar
        self._batt_start_pct = s['start_pct']
        self._batt_end_pct   = s['end_pct']
        self._batt_color     = color
        self._batt_bar_outer.queue_draw()
        self._batt_start_lbl.set_text(f'Started at {s["start_pct"]}%')
        self._batt_end_lbl.set_text(f'Ended at {s["end_pct"]}%')

        # Chart label
        chart_lbl = 'Battery level over time'
        if sleep_count > 0:
            chart_lbl += '  ·  - - - = sleeping'
        self._detail_chart_lbl.set_text(chart_lbl)

        # Chart (in thread to avoid blocking UI)
        def render_chart():
            pb = make_detail_pixbuf(s, self._dpi)
            def update():
                if pb:
                    w = 680
                    h = int(pb.get_height() * w / pb.get_width())
                    scaled = pb.scale_simple(w, h, GdkPixbuf.InterpType.BILINEAR)
                    self._detail_chart_image.set_from_pixbuf(scaled)
                return False
            GLib.idle_add(update)
        threading.Thread(target=render_chart, daemon=True).start()

        # Points
        self._detail_points_card._val_lbl.set_text(str(len(s['points'])))

        self._stack.set_visible_child_name('detail')

    # ── TAB SWITCHING ─────────────────────────────────────────────────────────

    def _switch_tab(self, name):
        self._tab_overview.get_style_context().add_class('tab-btn-active')
        if name == 'overview':
            if self._selected_idx is not None:
                self._stack.set_visible_child_name('detail')
            else:
                self._stack.set_visible_child_name('overview')
                self._refresh_overview()

    # ── EVENT HANDLERS ────────────────────────────────────────────────────────

    def _on_session_activated(self, listbox, row):
        if not hasattr(row, '_session_idx'):
            return
        idx = row._session_idx
        if idx == self._selected_idx:
            # Deselect → show overview
            self._selected_idx = None
            self._stack.set_visible_child_name('overview')
            self._refresh_overview()
        else:
            self._show_session_detail(idx)

    def _on_hide_session(self, btn, idx):
        s = self._sessions[idx]
        self._hidden_ts.add(int(s['start_ts']))
        save_hidden_ts(self._hidden_ts)
        self._hidden_idxs = resolve_hidden_idxs(self._sessions, self._hidden_ts)
        if self._selected_idx == idx:
            self._selected_idx = None
            self._stack.set_visible_child_name('overview')
        self._refresh_sidebar()
        self._refresh_overview()

    def _on_restore_clicked(self, btn):
        hidden = [(i, s) for i, s in enumerate(self._sessions)
                  if i in self._hidden_idxs]
        if not hidden:
            return

        dialog = Gtk.Dialog(title='Restore Hidden Sessions',
                            transient_for=self, flags=0)
        dialog.add_button('Close', Gtk.ResponseType.CLOSE)
        dialog.set_default_size(400, 300)

        content = dialog.get_content_area()
        lbl = _label('Click a session to restore it:', css_class=None)
        lbl.set_margin_start(16)
        lbl.set_margin_top(12)
        lbl.set_margin_bottom(8)
        content.pack_start(lbl, False, False, 0)

        listbox = Gtk.ListBox()
        listbox.set_selection_mode(Gtk.SelectionMode.NONE)
        for i, s in hidden:
            row = Gtk.ListBoxRow()
            row._session_idx = i
            inner = _box(Gtk.Orientation.HORIZONTAL, 12)
            inner.set_margin_start(12)
            inner.set_margin_end(12)
            inner.set_margin_top(8)
            inner.set_margin_bottom(8)
            date_lbl = _label(
                s['start'].strftime('%b %-d, %Y  %-I:%M %p'), css_class=None)
            dur_lbl = _label(fmt_duration(s['duration_h']), css_class=None)
            color = RATING_COLORS.get(s['usage_rating'], GOOD)
            _set_color(dur_lbl, color)
            restore_btn = Gtk.Button(label='Restore')
            restore_btn.connect('clicked', self._do_restore, i, dialog)
            inner.pack_start(date_lbl, True, True, 0)
            inner.pack_start(dur_lbl,  False, False, 0)
            inner.pack_end(restore_btn, False, False, 0)
            row.add(inner)
            listbox.add(row)

        sw = _scrolled(listbox)
        sw.set_min_content_height(200)
        content.pack_start(sw, True, True, 0)
        content.show_all()
        dialog.run()
        dialog.destroy()

    def _do_restore(self, btn, idx, dialog):
        s = self._sessions[idx]
        self._hidden_ts.discard(int(s['start_ts']))
        save_hidden_ts(self._hidden_ts)
        self._hidden_idxs = resolve_hidden_idxs(self._sessions, self._hidden_ts)
        self._refresh_sidebar()
        self._refresh_overview()
        # Rebuild the dialog list (simpler to close + reopen)
        dialog.response(Gtk.ResponseType.CLOSE)

    # ── UPDATE CHECK ──────────────────────────────────────────────────────────

    def _on_check_update(self, btn):
        btn.set_sensitive(False)
        btn.set_label('Checking…')

        def check():
            try:
                url = f'https://api.github.com/repos/{REPO}/releases/latest'
                req = urllib.request.Request(url, headers={'User-Agent': 'BatteryLens'})
                with urllib.request.urlopen(req, timeout=8) as resp:
                    data = json.loads(resp.read())
                latest = data.get('tag_name', '').lstrip('v')
                notes  = data.get('body', '')
                assets = data.get('assets', [])
                installer_url = next(
                    (a['browser_download_url'] for a in assets
                     if a['name'].endswith('.sh')), None)
                GLib.idle_add(self._show_update_result,
                              latest, notes, installer_url, None)
            except Exception as e:
                GLib.idle_add(self._show_update_result, None, None, None, str(e))

        threading.Thread(target=check, daemon=True).start()

    def _show_update_result(self, latest, notes, installer_url, error):
        btn = None
        for w in self._sidebar_find_update_btn():
            btn = w
        if btn:
            btn.set_label('⟳ Check for updates')
            btn.set_sensitive(True)

        if error:
            self._show_dialog('Update check failed',
                              f'Could not reach GitHub: {error}')
            return

        def _ver_tuple(v):
            try: return tuple(int(x) for x in v.split('.'))
            except: return (0,)

        current = _ver_tuple(VERSION)
        remote  = _ver_tuple(latest)

        if remote <= current:
            self._show_dialog('BatteryLens is up to date',
                              f'You are running v{VERSION} (latest).')
            return

        # New version available
        dialog = Gtk.Dialog(title='Update Available', transient_for=self, flags=0)
        dialog.set_default_size(460, 300)
        ca = dialog.get_content_area()
        ca.set_spacing(12)
        ca.set_margin_start(20)
        ca.set_margin_end(20)
        ca.set_margin_top(16)
        ca.set_margin_bottom(16)

        ca.pack_start(_label(f'BatteryLens v{latest} is available',
                             css_class=None), False, False, 0)
        ca.pack_start(_label(f'You have v{VERSION}', css_class=None),
                      False, False, 0)

        if notes:
            notes_lbl = _label(notes[:500], css_class=None)
            notes_lbl.set_line_wrap(True)
            notes_lbl.set_xalign(0)
            _set_color(notes_lbl, SUBTEXT)
            ca.pack_start(notes_lbl, False, False, 4)

        btn_box = _box(Gtk.Orientation.HORIZONTAL, 8)
        btn_box.set_halign(Gtk.Align.END)
        cancel = Gtk.Button(label='Not now')
        cancel.connect('clicked', lambda _: dialog.response(Gtk.ResponseType.CANCEL))
        btn_box.pack_start(cancel, False, False, 0)

        if installer_url:
            update = Gtk.Button(label='Update now')
            update.get_style_context().add_class('suggested-action')
            update.connect('clicked', lambda _: (
                dialog.response(Gtk.ResponseType.OK)))
            btn_box.pack_start(update, False, False, 0)

        ca.pack_start(btn_box, False, False, 0)
        ca.show_all()

        resp = dialog.run()
        dialog.destroy()

        if resp == Gtk.ResponseType.OK and installer_url:
            self._run_update(installer_url, latest)

    def _run_update(self, url, version):
        info = Gtk.MessageDialog(
            transient_for=self, flags=0,
            message_type=Gtk.MessageType.INFO,
            buttons=Gtk.ButtonsType.OK,
            text=f'Downloading BatteryLens v{version}…')
        info.format_secondary_text(
            'The installer will run in a terminal window.\n'
            'BatteryLens will restart after the update.')
        info.run()
        info.destroy()

        def do_update():
            try:
                import tempfile
                with tempfile.NamedTemporaryFile(
                        delete=False, suffix='.sh', mode='wb') as f:
                    req = urllib.request.Request(
                        url, headers={'User-Agent': 'BatteryLens'})
                    with urllib.request.urlopen(req, timeout=60) as resp:
                        f.write(resp.read())
                    tmp = f.name
                os.chmod(tmp, 0o755)
                subprocess.Popen(
                    ['bash', '-c',
                     f'bash {tmp} && sleep 1 && batterylens'],
                    start_new_session=True)
                GLib.idle_add(Gtk.main_quit)
            except Exception as e:
                GLib.idle_add(self._show_dialog, 'Update failed', str(e))

        threading.Thread(target=do_update, daemon=True).start()

    def _sidebar_find_update_btn(self):
        # Helper to find the update button in the sidebar header
        results = []
        def walk(w):
            if isinstance(w, Gtk.Button) and 'update' in (w.get_label() or '').lower():
                results.append(w)
            if hasattr(w, 'get_children'):
                for c in w.get_children():
                    walk(c)
        walk(self._paned.get_child1())
        return results

    def _show_dialog(self, title, message):
        dialog = Gtk.MessageDialog(
            transient_for=self, flags=0,
            message_type=Gtk.MessageType.INFO,
            buttons=Gtk.ButtonsType.OK,
            text=title)
        dialog.format_secondary_text(message)
        dialog.run()
        dialog.destroy()
        return False


# ═══════════════════════════════════════════════════════════════════════════════
# ENTRY POINT
# ═══════════════════════════════════════════════════════════════════════════════

if __name__ == '__main__':
    try:
        win = BatteryLensWindow()
        win.show_all()
        Gtk.main()
    except Exception:
        import traceback
        traceback.print_exc()
        # Show error dialog
        dialog = Gtk.MessageDialog(
            flags=0,
            message_type=Gtk.MessageType.ERROR,
            buttons=Gtk.ButtonsType.OK,
            text='BatteryLens failed to start')
        dialog.format_secondary_text(traceback.format_exc()[-1000:])
        dialog.run()
        dialog.destroy()
        sys.exit(1)

BATTERYLENS_APP_END
ok "App file written"
info "Installing icon..."
mkdir -p "$ICON_THEME_DIR"
echo 'iVBORw0KGgoAAAANSUhEUgAAAQAAAAEACAYAAABccqhmAABuFUlEQVR42u29d5xdV3U2/Ky9z7ltmkbNkmXJDRcsU4wLNhg0CgZMM6bMADHgBAImvCEJb8hL3nxJ7twEQkL4EiBAgHwJhM4dIJhiUwwaYZrBBQNyw1WWizQqU2855+y1vj9O2+fca8LINrbk8/x+LhrNzJ079+6113rWs54FFChQoECBAgUKFChQoECBAgUKFChQoECBAgUKFChQoECBAgUKFChQoECBAgUKFChQoECBAgUKFChQoECBAgUKFChQoECBAgUKFChQoECBAgUKFChQoECBAgUKFChQoECBAgUKFChQoECBAgUKFChQoECBAgUKFChQoECBAgUKFChQoECBAgUKFChQoECBAgUKFChQoECBAgUKFChQoECBAgUKFCjwGAcVv4LDFyISv740NTVFa9bsIIw98OePYZKJiIvf3GMHTvErOHwO+xSm1BrsIACYBuzDLL/Zd2mgLnXVoEYRBIoAUODRe9pBgjpNT0PNjG2WCZowRCQATC4ouLOYHbhn9mfHzAV3uJoHH9+RhUrbHOABd9VxA87wqlawxKQM6ZLeVe6u/uZT6Pk/bTabemJiwhS/6KIEKPCoSuen1BSACcofToX75Nq197RvOdHzFp/cNYsne4F/IpE6jmFWQGQVNKNcKQEkYAlARCAosDAEBiDAMUMwC6W/fNaGN7yrKU3d+zgFigBQ4BE49FOYoCljf/z67mUntFqzZ5ugO+arxSd2TftxTolGnDIAYgS+gfEFxjB83wACIaLwpIMgIlFlQCAiACRKQQ+PDit/n/vW8za8+b1NGdf24xYoAkCB30J630RTIXfob5m/ds087jh3Kdh7vo/Fp/lB96TqYMkFAM/rwvN8BB4LkTJEBIiQgAgQAohAAFkvdxgAwncAQYHCoMDiBESm1D198LkbNwyfsVdEKCovChQcQIGH87afxqTeSo1gAmHqfcv8tWv2847z2jx/4e2tK57lDmAVygGCboDAGMzPdg1AAkBBQEoRCeAIJLzV4zNOgAgAkiwbSOG/BAIQIBDFnnB1WFXu6Ow4C8Bl09OTGkBQvEJFACjwMKAudbUZN1CYniMQEf39mf96DqvO793Z3fas8gBWiQQI/Da688aASAClCIoIogUUxYBsQhce6ijdj/6Kw0gT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' | base64 -d > "$ICON_SRC"
cp "$ICON_SRC" "$ICON_THEME_FILE"
gtk-update-icon-cache -f -t "$HOME/.local/share/icons/hicolor" 2>/dev/null || true
kbuildsycoca6 2>/dev/null || kbuildsycoca5 2>/dev/null || true
ok "Icon installed"

info "Creating Python virtual environment..."
python3 -m venv --system-site-packages "$VENV_DIR"
ok "Virtual environment ready"
info "Installing matplotlib..."
"$VENV_DIR/bin/pip" install --quiet --upgrade pip
"$VENV_DIR/bin/pip" install --quiet matplotlib numpy
ok "matplotlib installed"
cat > "$LAUNCHER" << EOF
#!/usr/bin/env bash
"$VENV_DIR/bin/python" "$APP_FILE" 2>&1
EOF
chmod +x "$LAUNCHER"
ok "Launcher created"
cat > "$DESKTOP_DIR/batterylens.desktop" << EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=BatteryLens
GenericName=Battery History Viewer
Comment=Phone-style battery charge session history
Exec=$LAUNCHER
Icon=batterylens
Terminal=false
Categories=Utility;System;
Keywords=battery;power;charge;laptop;energy;
StartupNotify=true
StartupWMClass=BatteryLens
EOF
update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true
kbuildsycoca6 2>/dev/null || kbuildsycoca5 2>/dev/null || true
ok "App registered"
echo ""
echo -e "${GREEN}${BOLD}✅ BatteryLens installed!${RESET}"
echo ""
echo -e "   ${BOLD}Terminal:${RESET}  batterylens"
echo -e "   ${BOLD}App menu:${RESET}  Search 'BatteryLens' in launcher"
echo ""
echo -e "   To uninstall:"
echo -e "     rm -rf $APP_DIR $LAUNCHER $DESKTOP_DIR/batterylens.desktop $ICON_THEME_FILE"
echo ""
