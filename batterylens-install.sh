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
Version: 1.1.3
Repository: https://github.com/Filoviridae/batterylens
"""

import gi
gi.require_version('Gtk', '3.0')
gi.require_version('Gdk', '3.0')
gi.require_version('Pango', '1.0')
from gi.repository import Gtk, Gdk, GLib, GdkPixbuf, Gio, Pango

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
# Was 'cairo' — switched to the standard Agg backend after discovering it
# silently drops FancyBboxPatch corner rounding (used for the bar-chart
# style) while rendering everything else identically. All chart output
# already went through _fig_to_pixbuf's plain fig.savefig(..., format='png'),
# so this is a drop-in swap, not a behavior change for anything else.
matplotlib.use('agg')
import matplotlib.pyplot as plt
import matplotlib.patches as mpatches
import matplotlib.transforms as mtransforms
import numpy as np
from matplotlib.ticker import FuncFormatter, MaxNLocator

# Must match the installed .desktop file's basename so GNOME Shell (Wayland
# app_id lookup) and window managers (X11 WM_CLASS) resolve the right icon
# instead of falling back to the Python interpreter's icon.
GLib.set_prgname('io.github.filoviridae.batterylens')
GLib.set_application_name('BatteryLens')

VERSION = "1.1.3"
REPO = "Filoviridae/batterylens"
SLEEP_GAP_THRESHOLD_S = 900  # 15 min
LONG_GAP_THRESHOLD_S = 86400  # 24h — beyond this, condense the gap on charts
LONG_GAP_DISPLAY_H = 0.12     # fixed on-chart width given to any condensed gap

APP_DIR   = os.path.expanduser('~/.local/share/batterylens')
HIDDEN_FILE = os.path.join(APP_DIR, 'hidden_sessions.json')
UNKNOWN_STATES_FILE = os.path.join(APP_DIR, 'unknown_states.json')
CHART_PREFS_FILE = os.path.join(APP_DIR, 'chart_prefs.json')
ICON_PATH   = os.path.join(APP_DIR, 'batterylens-icon.png')

DEFAULT_CHART_PREF = {'style': 'line', 'granularity_h': 1}
GRANULARITY_CHOICES_H = (1, 2, 4)

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

FULL_EQUIV_TOOLTIP = (
    "Projected 100% → 0% battery life, based on the drain rate actually "
    "observed during active/screen-on time — scaled up if the session "
    "didn't run the full range."
)

# ── CSS ───────────────────────────────────────────────────────────────────────
CSS = """
* { font-family: "Inter", "Cantarell", sans-serif; }

/* Force dark background on the window itself; plain layout containers stay
   transparent so nested boxes don't paint an opaque rectangle on top of a
   differently-coloured card (session-row, bat-strip, stat-box, etc.) */
window {
    background-color: #1C1C1E;
    color: #FFFFFF;
}
box, grid, scrolledwindow, viewport,
stack, paned, frame, eventbox,
list, row {
    background-color: transparent;
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
row { background-color: transparent; outline: none; }
row:hover { background-color: transparent; }

/* Dialog — messagedialog is a distinct CSS node type from plain dialog
   (GtkMessageDialog names its own node "messagedialog"), so both need
   covering or one falls back to the system's light theme background while
   still inheriting this app's white text color from the `box` rule below,
   producing near-invisible white-on-white text. */
dialog, messagedialog { background-color: #2C2C2E; }
dialog box, messagedialog box { background-color: #2C2C2E; }
.dialog-action-area { background-color: #2C2C2E; }

/* ── Title bar ── */
#app-headerbar {
    background-color: #1C1C1E;
    background-image: none;
    color: #FFFFFF;
    border-bottom: 1px solid #3A3A3C;
    box-shadow: none;
}
#app-headerbar button {
    background: none;
    color: #8E8E93;
}
#app-headerbar button:hover { background-color: #3A3A3C; color: #FFFFFF; }

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
#session-list-scroll list {
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
.discharge-banner {
    background-color: rgba(0,122,255,0.15);
    border-radius: 8px;
    padding: 8px 12px;
    font-size: 13px;
    color: #007AFF;
    font-weight: 600;
}

/* ── Live charging card (sidebar) ── */
.charging-card {
    background-color: rgba(52,199,89,0.14);
    border: 1px dashed rgba(52,199,89,0.55);
    border-radius: 12px;
    padding: 10px 12px;
}
.charging-card:hover { background-color: rgba(52,199,89,0.20); }
.charge-badge {
    background-color: rgba(52,199,89,0.22);
    border-radius: 6px;
    padding: 2px 8px;
    font-size: 10px;
    font-weight: 700;
    color: #34C759;
}
.charge-pct { font-size: 20px; font-weight: 800; color: #FFFFFF; }
.charge-rate { font-size: 11px; color: #8E8E93; }
.charge-sub { font-size: 11px; color: #8E8E93; }

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

/* ── Chart style / granularity toggle buttons ── */
.style-toggle {
    font-size: 11px;
    font-weight: 600;
    padding: 3px 10px;
    margin: 0;
    min-height: 0;
    min-width: 0;
    border-radius: 6px;
}
.style-toggle-active {
    background-color: rgba(0,122,255,0.15);
    color: #007AFF;
}

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
    unknown_entries = []
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
                            # upowerd occasionally logs bogus 'unknown' rows that
                            # aren't real state transitions; keep them out of
                            # session parsing so they don't split a session that's
                            # actually still discharging.
                            if state == 'unknown':
                                unknown_entries.append({
                                    'ts': ts, 'val': val, 'state': state,
                                    'source_file': os.path.basename(fpath)
                                })
                                continue
                            all_entries.append({
                                'ts': ts, 'val': val, 'state': state,
                                'dt': datetime.datetime.fromtimestamp(ts)
                            })
                        except (ValueError, OSError):
                            pass
        except (IOError, PermissionError):
            pass
    if unknown_entries:
        def _key(e):
            return (e['ts'], e['val'], e['state'], e['source_file'])
        saved = load_unknown_states()
        seen = {_key(e) for e in saved}
        new = []
        for e in unknown_entries:
            k = _key(e)
            if k not in seen:
                seen.add(k)
                new.append(e)
        if new:
            saved.extend(new)
            saved.sort(key=lambda e: e['ts'])
            save_unknown_states(saved)
    if not all_entries:
        return [], None
    all_entries.sort(key=lambda x: x['ts'])
    return _extract_sessions(all_entries), _extract_charging_session(all_entries)

def _extract_sessions(entries):
    sessions = []
    current = None
    prev_entry = None

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
                # A long gap since the last log entry of any kind (lid
                # closed, machine off/suspended) sits between sessions and
                # would otherwise be lost entirely. Bridge it with the real
                # prior reading so the sleep-gap logic in _finalize picks it
                # up automatically — extending duration/idle and drawing the
                # true drop on the chart, without touching active_drain.
                if prev_entry is not None and e['ts'] - prev_entry['ts'] > SLEEP_GAP_THRESHOLD_S:
                    lead = {'ts': prev_entry['ts'], 'val': prev_entry['val'],
                            'dt': prev_entry['dt'], 'state': prev_entry['state']}
                    current['points'].insert(0, lead)
                    current['start']    = lead['dt']
                    current['start_ts'] = lead['ts']
                    current['start_pct'] = lead['val']
            else:
                current['points'].append(e)
        else:
            s = _close(current)
            if s:
                sessions.append(s)
            current = None
        prev_entry = e

    if current and len(current['points']) >= 2:
        last = current['points'][-1]
        recency_s = time.time() - last['ts']
        is_active = recency_s < 1800
        s = _close(current, active=is_active)
        if s:
            sessions.append(s)

    return sessions

def _extract_charging_session(entries):
    """Returns the current in-progress charging streak — the contiguous run
    of 'charging' entries at the tail of the (sorted) log — or None if the
    device isn't currently charging or upowerd hasn't logged enough of it
    yet. Mirrors the 'active' discharge-session recency check above."""
    if not entries or entries[-1]['state'] != 'charging':
        return None
    if time.time() - entries[-1]['ts'] >= 1800:
        return None

    pts = []
    for e in reversed(entries):
        if e['state'] != 'charging':
            break
        pts.append(e)
    pts.reverse()
    if len(pts) < 2:
        return None

    start, end = pts[0], pts[-1]
    duration_h = (end['ts'] - start['ts']) / 3600
    if duration_h <= 0:
        return None
    rate = (end['val'] - start['val']) / duration_h

    return {
        'start': start['dt'], 'start_ts': start['ts'],
        'start_pct': round(start['val']), 'current_pct': round(end['val']),
        'points': pts, 'duration_h': duration_h, 'rate_pct_per_h': rate,
    }

def _finalize(s):
    pts   = s['points']
    drain = s['start_pct'] - s['end_pct']
    dur_h = s['duration_h']

    intervals = [pts[i]['ts'] - pts[i-1]['ts'] for i in range(1, len(pts))]
    active_s = 0
    active_drain = 0
    sleep_gaps = []
    for i in range(1, len(pts)):
        gap = pts[i]['ts'] - pts[i-1]['ts']
        if gap > SLEEP_GAP_THRESHOLD_S:
            sleep_gaps.append((pts[i-1]['ts'], pts[i]['ts'], pts[i-1]['val']))
        else:
            active_s += gap
            active_drain += pts[i-1]['val'] - pts[i]['val']
    active_h = active_s / 3600

    # Rating/projection is defined (see FULL_EQUIV_TOOLTIP) as the rate
    # observed during active/screen-on time — use active_drain, not the
    # whole-session drain, so a long sleep/off gap (which can lose many
    # percentage points with zero real usage) never skews it.
    if active_drain > 0 and active_h > 0:
        full_equiv_h = active_h * (100 / active_drain)
    elif active_drain > 0:
        full_equiv_h = dur_h * (100 / active_drain)
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


# ── Unknown-state entries persistence ─────────────────────────────────────────
# upowerd occasionally logs bogus rows (val=0, state='unknown') that aren't
# real charge/discharge transitions. They're dropped from session parsing
# (see _read_upower_history) but kept here in case the raw data is ever
# useful for debugging upowerd behaviour.

def load_unknown_states():
    try:
        with open(UNKNOWN_STATES_FILE) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return []

def save_unknown_states(entries):
    try:
        with open(UNKNOWN_STATES_FILE, 'w') as f:
            json.dump(entries, f, indent=2)
    except Exception:
        pass

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

# ── Per-session chart style persistence ───────────────────────────────────────
# Keyed by session start_ts (same identity used for hidden sessions) so a
# session keeps its line/bar + granularity choice across app restarts even
# though sessions are re-derived from the raw upower log every launch.

def load_chart_prefs():
    try:
        with open(CHART_PREFS_FILE) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {}

def save_chart_prefs(prefs):
    try:
        with open(CHART_PREFS_FILE, 'w') as f:
            json.dump(prefs, f, indent=2)
    except Exception:
        pass

def get_chart_pref(prefs, session):
    return prefs.get(str(int(session['start_ts'])), DEFAULT_CHART_PREF)


# ═══════════════════════════════════════════════════════════════════════════════
# CHART LAYER  (matplotlib → Cairo surface → Gtk.DrawingArea)
# ═══════════════════════════════════════════════════════════════════════════════

def _fig_to_pixbuf(fig, dpi=150, tight=True):
    """Render a matplotlib figure to a GdkPixbuf via PNG.

    tight=False skips bbox_inches='tight' — that crop happens after
    ax.get_position() is captured elsewhere, so it silently invalidates any
    figure-relative bbox fractions computed beforehand (needed for mapping
    cursor position to data points for hover tooltips)."""
    buf = io.BytesIO()
    kwargs = dict(bbox_inches='tight') if tight else {}
    fig.savefig(buf, format='png', dpi=dpi,
                facecolor=fig.get_facecolor(), **kwargs)
    buf.seek(0)
    loader = GdkPixbuf.PixbufLoader.new_with_type('png')
    loader.write(buf.read())
    loader.close()
    return loader.get_pixbuf()

def _compress_xs(pts):
    """Map each point to an on-chart x position in hours, collapsing any
    gap longer than LONG_GAP_THRESHOLD_S (e.g. the machine off/suspended
    for days) down to a small fixed width — otherwise a multi-day gap
    stretches the axis so far that the real (often much shorter) active
    portion of the session gets squashed into an unreadable sliver. The
    true skipped duration is still conveyed via a text annotation drawn
    over the condensed segment (see _draw_discharge_line), not its width.

    Returns (xs, breaks) where breaks is a list of (disp_x_start,
    disp_x_end, real_start_h, real_end_h) for each condensed gap.
    """
    xs = [0.0]
    breaks = []
    for i in range(1, len(pts)):
        gap_s = pts[i]['ts'] - pts[i-1]['ts']
        real_h = (pts[i]['ts'] - pts[0]['ts']) / 3600
        if gap_s > LONG_GAP_THRESHOLD_S:
            disp = xs[-1] + LONG_GAP_DISPLAY_H
            real_prev_h = (pts[i-1]['ts'] - pts[0]['ts']) / 3600
            breaks.append((xs[-1], disp, real_prev_h, real_h))
        else:
            disp = xs[-1] + gap_s / 3600
        xs.append(disp)
    return xs, breaks

def _smart_xticks(ax, xs, pts=None, breaks=None, max_h=None):
    # Smaller candidates matter for a freshly-started active session, which
    # might only have ~1 hour (or less) of data. Pick whichever step lands
    # the tick count closest to the middle of a 4-9 tick sweet spot, rather
    # than the first exact match — consecutive candidates' [4,9]-tick windows
    # don't all overlap (e.g. 0.1h and 0.25h leave a gap around 0.9-1.0h), so
    # "first match, else 24h" used to silently fall through to a useless
    # single "0h, 24h" tick pair for durations landing in one of those gaps.
    nice = [0.05, 0.1, 0.25, 0.5, 1, 2, 3, 4, 6, 8, 12, 24]
    disp_max = max_h if max_h is not None else (xs[-1] if xs else 0)
    # matplotlib silently widens the axis to fit any tick outside the current
    # xlim (confirmed: set_xticks([x]) with x > xlim[1] moves xlim[1] to x) —
    # so an off-by-one tick past disp_max doesn't just look odd, it blows the
    # compressed axis back out to whatever that stray tick's position was.
    # Every candidate list below must be hard-clipped to disp_max.
    eps = 1e-9

    if not breaks:
        step = min(nice, key=lambda s: abs(disp_max / s - 6))
        ticks = [t for t in np.arange(0, disp_max + step, step) if t <= disp_max + eps]
        ax.set_xticks(ticks)
        ax.set_xticklabels([f'{x:.0f}h' if x == int(x) else f'{x:.1f}h' for x in ticks],
                           color=SUBTEXT, fontsize=8)
        return

    # One or more gaps were condensed, so a single global step (picked from
    # the mostly-condensed real duration) is the wrong tool — it's either
    # so coarse the real (usually short) active portion gets zero ticks, or
    # it lands candidates inside the condensed span with nowhere sane to put
    # them. Instead, tick each contiguous "run" between condensed gaps on
    # its own scale: real hours map 1:1 to display hours *within* a run (by
    # construction of _compress_xs), so each run gets exactly the same
    # nice-step treatment as an uncondensed chart, just offset to where that
    # run actually sits.
    real_last_h = (pts[-1]['ts'] - pts[0]['ts']) / 3600
    real_max_h = real_last_h + max(0, disp_max - xs[-1])

    runs = []  # (real_start_h, real_end_h, disp_start, disp_end)
    real_cursor, disp_cursor = 0.0, 0.0
    for disp_start, disp_end, real_start_h, real_end_h in breaks:
        runs.append((real_cursor, real_start_h, disp_cursor, disp_start))
        real_cursor, disp_cursor = real_end_h, disp_end
    runs.append((real_cursor, real_max_h, disp_cursor, disp_max))

    tick_positions, tick_labels = [], []
    seen = set()
    for real_start_h, real_end_h, disp_start, disp_end in runs:
        span = real_end_h - real_start_h
        if span <= eps:
            candidates = [real_start_h]
        else:
            step = min(nice, key=lambda s: abs(span / s - 6))
            lo = math.floor((real_start_h - eps) / step) * step
            candidates = [c for c in np.arange(lo, real_end_h + step, step)
                          if real_start_h - eps <= c <= real_end_h + eps]
        for c in candidates:
            frac = (c - real_start_h) / span if span > eps else 0
            d = disp_start + frac * (disp_end - disp_start)
            if d > disp_max + eps:
                continue
            key = round(d, 4)
            if key in seen:
                continue
            seen.add(key)
            tick_positions.append(d)
            tick_labels.append(f'{c:.0f}h' if c == int(c) else f'{c:.1f}h')

    ax.set_xticks(tick_positions)
    ax.set_xticklabels(tick_labels, color=SUBTEXT, fontsize=8)

def _fmt_gap_duration(hours):
    d, h = int(hours // 24), int(hours % 24)
    if d > 0:
        return f'{d}d {h}h' if h else f'{d}d'
    return fmt_duration(hours)

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
    ax.tick_params(colors=SUBTEXT, which='both', length=0, labelsize=8)
    # Let matplotlib auto-pick gridlines that actually fall within whatever
    # ylim gets set later, instead of fixed 0/25/50/75/100 positions — those
    # go missing entirely on a zoomed-in range (e.g. a fresh active session
    # that's only dropped a few percent), leaving just one visible gridline.
    # integer=True forces whole-number tick positions — without it, a
    # gridline can land at e.g. 97.5% while its label is rounded to "98%",
    # making a data point that's genuinely at 98% look off the line.
    ax.yaxis.set_major_locator(MaxNLocator(nbins=5, steps=[1, 2, 5, 10], integer=True))
    ax.yaxis.set_major_formatter(FuncFormatter(lambda v, _: f'{v:.0f}%'))

def _draw_discharge_line(ax, pts, xs, ys, color, show_points=False):
    """Draw solid line for active periods, dashed for sleep gaps."""
    active_xs, active_ys = [xs[0]], [ys[0]]
    any_sleep = False
    first_sleep = True
    first_active = [True]
    # Bigger + a contrasting edge — the chart is rendered at high DPI then
    # downscaled to fit the display width, so small same-color markers
    # shrink into the line itself and disappear after that downscale
    point_kwargs = dict(marker='o', markersize=6,
                         markeredgewidth=1, markeredgecolor=BG2) if show_points else {}

    def flush(rxs, rys):
        if len(rxs) < 2:
            return
        ax.fill_between(rxs, rys, alpha=0.2, color=color, zorder=3)
        lbl = 'Active' if first_active[0] else None
        ax.plot(rxs, rys, color=color, linewidth=2.5,
                solid_capstyle='round', zorder=5, label=lbl, **point_kwargs)
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
                    alpha=0.7, zorder=4, label=lbl, **point_kwargs)
            first_sleep = False
            if gap > LONG_GAP_THRESHOLD_S:
                # Condensed on the x-axis (see _compress_xs) to a near-zero
                # width — the actual duration is shown in a badge above the
                # chart (_show_session_detail), not here. This just marks the
                # break as a long sleep with the same moon glyph, so it reads
                # as "more of the same, just longer" rather than a new symbol.
                mid_x = (xs[i-1] + xs[i]) / 2
                moon_y = min(max(ys[i-1], ys[i]) + 4, 97)
                offset_t = mtransforms.offset_copy(
                    ax.transData, fig=ax.figure, x=2.2, y=2.6, units='points')
                ax.scatter([mid_x], [moon_y], s=46, color=SLEEP_LINE, zorder=7,
                           linewidths=0)
                ax.scatter([mid_x], [moon_y], s=38, color=BG2, zorder=8,
                           transform=offset_t, linewidths=0)
            active_xs, active_ys = [xs[i]], [ys[i]]
        else:
            active_xs.append(xs[i])
            active_ys.append(ys[i])

    flush(active_xs, active_ys)
    ax.plot(xs[-1], ys[-1], 'o', color=color, markersize=7, zorder=6)

    if any_sleep:
        ax.legend(fontsize=8, facecolor=BG2, edgecolor=BG3,
                  labelcolor=SUBTEXT, loc='upper right')

def make_detail_pixbuf(session, dpi=150, show_points=False):
    """Returns (pixbuf, meta) — meta captures the axes' bounding box as a
    figure-relative fraction (independent of any later display scaling) plus
    the data range, so a hover handler can map cursor position back to the
    nearest data point without re-deriving matplotlib's tight_layout math."""
    pts = session['points']
    xs, breaks = _compress_xs(pts)
    ys  = [p['val'] for p in pts]
    color = RATING_COLORS.get(
        'active' if session.get('active') else session['usage_rating'], GOOD)

    xlim = (min(xs) - 0.05, max(xs) + 0.05)
    ylim = (max(0, min(ys) - 10), 100)

    fig, ax = plt.subplots(figsize=(6.5, 2.8))
    _style_ax(ax, fig)
    ax.set_xlim(*xlim)
    ax.set_ylim(*ylim)
    _draw_discharge_line(ax, pts, xs, ys, color, show_points=show_points)
    _smart_xticks(ax, xs, pts=pts, breaks=breaks)
    plt.tight_layout(pad=0.4)
    bbox = ax.get_position()
    pb = _fig_to_pixbuf(fig, dpi, tight=False)
    plt.close(fig)

    meta = {
        'bbox': (bbox.x0, bbox.y0, bbox.x1, bbox.y1),
        'xlim': xlim,
        'ylim': ylim,
        'points': [
            (x, p['val'], datetime.datetime.fromtimestamp(p['ts']).strftime('%-I:%M %p'))
            for x, p in zip(xs, pts)
        ],
    }
    return pb, meta

def _bucket_session(session, granularity_h):
    """Bucket a session's points into fixed granularity_h-hour buckets from
    the first reading onward. A bucket is 'real' if an actual sample falls
    within half a bucket-width of its mark, else 'idle' — held at the last
    real value seen so far (approved over a no-data marker: see the idle-bar
    mockup discussion). Unlike the line chart, this needs no long-gap/
    compression handling at all — every bucket is the same width regardless
    of how long a real gap behind it actually was."""
    pts = session['points']
    start_ts, end_ts = pts[0]['ts'], pts[-1]['ts']
    bucket_s = granularity_h * 3600
    tol_s = bucket_s / 2
    n_buckets = int((end_ts - start_ts) // bucket_s) + 1

    buckets = []
    pi = 0
    last_val = pts[0]['val']
    for b in range(n_buckets + 1):
        bucket_ts = start_ts + b * bucket_s
        while pi + 1 < len(pts) and pts[pi + 1]['ts'] <= bucket_ts + tol_s:
            pi += 1
        nearest = pts[pi]
        is_real = abs(nearest['ts'] - bucket_ts) <= tol_s
        val = nearest['val'] if is_real else last_val
        if is_real:
            last_val = val
        buckets.append({'ts': bucket_ts, 'val': val, 'real': is_real})
    return buckets

def make_detail_bar_pixbuf(session, granularity_h=1, dpi=150):
    """Bar-chart alternative to make_detail_pixbuf — same (pixbuf, meta)
    interface so the existing hover wiring works unchanged. Right-aligned
    y-axis and date-boundary separators mirror the approved mockup."""
    buckets = _bucket_session(session, granularity_h)
    color = RATING_COLORS.get(
        'active' if session.get('active') else session['usage_rating'], GOOD)
    n = len(buckets)
    bar_w = 0.82

    fig, ax = plt.subplots(figsize=(6.5, 2.8))
    _style_ax(ax, fig)
    ax.yaxis.tick_right()
    ax.yaxis.set_label_position('right')
    ax.yaxis.set_major_locator(MaxNLocator(nbins=3, steps=[5, 10], integer=True))
    xlim = (-0.6, n - 0.4)
    ylim = (0, 100)
    ax.set_xlim(*xlim)
    ax.set_ylim(*ylim)

    # Rounded-top bars (matches the approved Motorola-style mockup). A plain
    # ax.bar() can't round corners, so each bar is a FancyBboxPatch instead.
    # mutation_aspect must equal (axes pixel width / axes pixel height) /
    # (x data-range / y data-range) — i.e. pixels-per-x-unit divided by
    # pixels-per-y-unit — so the rounding looks circular in actual on-screen
    # pixels despite x (bucket index, range ~n) and y (0-100%) living on
    # wildly different data scales. Getting the ratio direction backwards
    # here silently produces a mutation_aspect ~30-150x too small and the
    # rounding vanishes rather than looking stretched, which is what made
    # this bug so easy to mistake for "no rounding at all, in any version."
    xrange_data = (n - 0.4) - (-0.6)
    yrange_data = 100
    axes_px_aspect = 2.38  # measured axes-box width/height once chrome/labels are laid out
    mutation_aspect = axes_px_aspect * (yrange_data / xrange_data)
    for i, b in enumerate(buckets):
        val = b['val']
        if val <= 0:
            continue
        patch = mpatches.FancyBboxPatch(
            (i - bar_w / 2, 0), bar_w, val,
            boxstyle='round,pad=0,rounding_size=0.16',
            mutation_aspect=mutation_aspect, linewidth=0, zorder=3,
            facecolor=color if b['real'] else SLEEP_LINE,
            alpha=1.0 if b['real'] else 0.55)
        ax.add_patch(patch)

    tick_positions, tick_labels = [], []
    prev_date = None
    last_date_label_i = None
    # A day boundary can fall just a few buckets after the previous one (a
    # session starting late in the day), which would overlap the previous
    # date label's text — the dashed boundary line is cheap to always draw,
    # but the text itself is only worth showing with enough room to read.
    min_label_gap = max(8, round(n * 0.10))
    label_every = max(1, round(6 / granularity_h))
    for i, b in enumerate(buckets):
        dt = datetime.datetime.fromtimestamp(b['ts'])
        if dt.date() != prev_date:
            ax.axvline(x=i - 0.5, color=BG3, linewidth=1, linestyle='--', zorder=1)
            if last_date_label_i is None or i - last_date_label_i >= min_label_gap:
                ax.text(i - 0.5, 102, dt.strftime('%a %-m/%d'), fontsize=8,
                        color=SUBTEXT, ha='left', fontweight='600')
                last_date_label_i = i
            prev_date = dt.date()
        elif i % label_every == 0:
            tick_positions.append(i)
            tick_labels.append(dt.strftime('%-I%p').lower())
    ax.set_xticks(tick_positions)
    ax.set_xticklabels(tick_labels, color=SUBTEXT, fontsize=8)

    plt.tight_layout(pad=0.4)
    bbox = ax.get_position()
    pb = _fig_to_pixbuf(fig, dpi, tight=False)
    plt.close(fig)

    meta = {
        'bbox': (bbox.x0, bbox.y0, bbox.x1, bbox.y1),
        'xlim': xlim,
        'ylim': ylim,
        'points': [
            (i, b['val'], datetime.datetime.fromtimestamp(b['ts']).strftime('%-I:%M %p')
             + ('' if b['real'] else ' (idle)'))
            for i, b in enumerate(buckets)
        ],
    }
    return pb, meta

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
    xs, breaks = _compress_xs(pts)
    ys   = [p['val'] for p in pts]
    now_h = xs[-1]

    fig, ax = plt.subplots(figsize=(6.5, 2.8))
    _style_ax(ax, fig)

    proj_end = now_h + (current_pct / avg_rate) if avg_rate > 0 else now_h + 2
    ax.set_xlim(-0.05, max(xs[-1] + 0.5, proj_end + 0.3))
    ax.set_ylim(0, 100)

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
    _smart_xticks(ax, xs, pts=pts, breaks=breaks, max_h=ax.get_xlim()[1])
    plt.tight_layout(pad=0.4)
    pb = _fig_to_pixbuf(fig, dpi)
    plt.close(fig)
    return pb

def make_sparkline_pixbuf(session, dpi=120):
    pts = session['points']
    xs, _breaks = _compress_xs(pts)
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

def make_charging_pixbuf(charging, dpi=150):
    pts = charging['points']
    xs  = [(p['ts'] - pts[0]['ts']) / 3600 for p in pts]
    ys  = [p['val'] for p in pts]

    fig, ax = plt.subplots(figsize=(6.5, 2.8))
    _style_ax(ax, fig)
    ax.set_xlim(min(xs) - 0.02, max(xs) + 0.02)
    ax.set_ylim(max(0, min(ys) - 5), min(100, max(ys) + 5))
    ax.fill_between(xs, ys, alpha=0.2, color=GREAT, zorder=3)
    ax.plot(xs, ys, color=GREAT, linewidth=2.5, solid_capstyle='round', zorder=5)
    ax.plot(xs[-1], ys[-1], 'o', color=GREAT, markersize=7, zorder=6)
    _smart_xticks(ax, max(xs) or 0.1)
    plt.tight_layout(pad=0.4)
    pb = _fig_to_pixbuf(fig, dpi)
    plt.close(fig)
    return pb


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

def _chart_width(card, default=680, min_w=280, max_w=900):
    """Chart render width from the card's real allocated width, so charts
    shrink/grow with the window instead of clipping at a fixed size."""
    alloc = card.get_allocated_width()
    if alloc <= 1:
        return default
    return max(min_w, min(max_w, alloc - 32))  # 32 = .chart-card's l/r padding

def _capped_image_wrapper(image, min_w=280, max_w=900):
    """Wrap a chart Gtk.Image in a ScrolledWindow with an explicit
    min/max-content-width. A bare Gtk.Image reports its full pixbuf size as
    its own minimum, which otherwise propagates straight up and pins the
    whole window's real minimum width to whatever the chart was last
    rendered at. Horizontal policy must be EXTERNAL (not NEVER) — with
    NEVER, GTK still reserves the child's full width to avoid clipping,
    regardless of min/max-content-width. EXTERNAL gets the same sizing
    benefit as AUTOMATIC but never actually shows a scrollbar widget (which
    would otherwise sit on top of the chart and intercept hover events)."""
    sw = Gtk.ScrolledWindow()
    sw.set_policy(Gtk.PolicyType.EXTERNAL, Gtk.PolicyType.NEVER)
    sw.set_min_content_width(min_w)
    sw.set_max_content_width(max_w)
    sw.set_min_content_height(1)
    sw.set_propagate_natural_width(False)
    # We never actually want scrolling/panning here — this ScrolledWindow
    # exists purely as a trick to get min/max-content-width sizing. Kinetic
    # scrolling can still engage a drag-to-pan cursor and gesture recognizer
    # (visible as the 4-way move cursor) whenever content is even a pixel
    # wider than the viewport, which also interferes with hover events.
    sw.set_kinetic_scrolling(False)
    sw.set_overlay_scrolling(False)
    sw.add(image)
    return sw


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
        # Kept low enough that GNOME's edge-tiling (snapping to half the
        # screen) isn't refused for being under the window's minimum size
        self.set_size_request(640, 480)
        self.connect('destroy', Gtk.main_quit)

        # Set window icon for taskbar
        if os.path.exists(ICON_PATH):
            try:
                pb = GdkPixbuf.Pixbuf.new_from_file(ICON_PATH)
                self.set_icon(pb)
            except Exception:
                pass
        self.set_wmclass('batterylens', 'BatteryLens')

        # Custom dark titlebar — the system default renders light/white and
        # clashes with the app's dark theme, since it's drawn outside our
        # own widget tree and isn't reachable by our CSS provider.
        headerbar = Gtk.HeaderBar()
        headerbar.set_show_close_button(True)
        headerbar.set_title('BatteryLens')
        headerbar.set_name('app-headerbar')
        self.set_titlebar(headerbar)

        # App state
        self._sessions     = []
        self._hidden_ts    = load_hidden_ts()
        self._hidden_idxs  = set()
        self._chart_prefs  = load_chart_prefs()
        self._selected_idx = None
        self._charging          = None
        self._charging_selected = False
        self._bat_info     = None
        self._had_active   = False
        self._resize_debounce_id = None
        self._show_data_points = False
        self._dpi = int(min(2.2, self.get_scale_factor() or 1) * 120)

        self._build_ui()
        self._apply_css()
        self._load_data()

        # _load_data() jumps to a newly-active session automatically; if none
        # was found, land on Overview instead of the blank empty state
        if self._selected_idx is None and self._visible_sessions():
            self._switch_tab('overview')

        # Primary refresh trigger: UPower emits a D-Bus signal the instant
        # the kernel reports a power-supply change (plugged in, unplugged,
        # charge state flips), so we react immediately instead of waiting
        # for the next poll. Falls back to poll-only if unavailable.
        self._live_refresh_debounce_id = None
        self._setup_live_power_signals()

        # Fallback safety net in case the D-Bus subscription above never
        # came up (unusual sandboxes, upowerd restarting mid-session) or a
        # signal gets missed — much less frequent now that it's not the
        # primary mechanism.
        GLib.timeout_add_seconds(300, self._auto_refresh)

        # Re-render charts if the display's scale factor changes (e.g. moving
        # to a different-DPI monitor) or the window is resized/tiled, so
        # charts stay sharp and correctly sized instead of stale/fixed-width
        self.connect('notify::scale-factor', self._on_scale_factor_changed)
        self.connect('configure-event', self._on_window_configure)

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

        self._stat_avg      = self._small_stat('—', 'Avg Life', FULL_EQUIV_TOOLTIP)
        self._stat_best     = self._small_stat('—', 'Best')
        self._stat_sessions = self._small_stat('0', 'Sessions')

        for s in [self._stat_avg, self._stat_best, self._stat_sessions]:
            stats_box.pack_start(s, True, True, 0)
        sidebar.pack_start(stats_box, False, False, 0)
        sidebar.pack_start(_separator(), False, False, 0)

        sidebar.pack_start(self._build_charging_card(), False, False, 0)

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

    def _build_charging_card(self):
        """Temporary card that appears above the session list while plugged
        in and charging, and disappears again once back on battery — mirrors
        the shape of a session-row card but is never written to history."""
        btn = Gtk.Button()
        btn.get_style_context().add_class('charging-card')
        btn.set_hexpand(True)
        btn.connect('clicked', lambda _b: self._show_charging_detail())

        inner = _box(spacing=4)

        self._charge_badge_lbl = _label('⚡ CHARGING', 'charge-badge')
        self._charge_badge_lbl.set_halign(Gtk.Align.START)
        inner.pack_start(self._charge_badge_lbl, False, False, 0)

        row = _box(Gtk.Orientation.HORIZONTAL, 6)
        self._charge_pct_lbl = _label('—', 'charge-pct')
        self._charge_rate_lbl = _label('', 'charge-rate')
        self._charge_rate_lbl.set_halign(Gtk.Align.END)
        self._charge_rate_lbl.set_hexpand(True)
        row.pack_start(self._charge_pct_lbl, False, False, 0)
        row.pack_start(self._charge_rate_lbl, True, True, 0)
        inner.pack_start(row, False, False, 0)

        self._charge_sub_lbl = _label('', 'charge-sub')
        self._charge_sub_lbl.set_xalign(0)
        self._charge_sub_lbl.set_line_wrap(True)
        inner.pack_start(self._charge_sub_lbl, False, False, 0)

        btn.add(inner)

        self._charging_revealer = Gtk.Revealer()
        self._charging_revealer.set_transition_type(Gtk.RevealerTransitionType.SLIDE_DOWN)
        self._charging_revealer.set_transition_duration(220)
        self._charging_revealer.set_reveal_child(False)
        self._charging_revealer.add(btn)
        self._charging_revealer.set_margin_start(8)
        self._charging_revealer.set_margin_end(8)
        self._charging_revealer.set_margin_bottom(6)
        return self._charging_revealer

    def _small_stat(self, val, lbl, tooltip=None):
        box = _box(spacing=1)
        box.get_style_context().add_class('stat-box')
        box.set_margin_start(3)
        box.set_margin_end(3)
        if tooltip:
            box.set_tooltip_text(tooltip)
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
        self._stack.add_named(self._build_charging_page(),  'charging')
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

        self._live_discharge_banner = _label(
            "● Currently discharging — this session will appear below once the "
            "system logs its first battery reading for it (can take a few minutes)",
            'discharge-banner')
        self._live_discharge_banner.set_line_wrap(True)
        self._live_discharge_banner.set_halign(Gtk.Align.START)
        self._live_discharge_banner.set_no_show_all(True)
        self._live_discharge_banner.hide()
        box.pack_start(self._live_discharge_banner, False, False, 4)

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
        self._overview_chart_card.pack_start(_capped_image_wrapper(self._overview_chart_image), False, False, 0)
        box.pack_start(self._overview_chart_card, False, False, 4)
        self._overview_chart_card.hide()

        # Stats grid
        self._ov_stat_grid = Gtk.Grid()
        self._ov_stat_grid.set_column_homogeneous(True)
        self._ov_stat_grid.set_row_spacing(0)
        self._ov_stat_grid.set_column_spacing(0)
        self._ov_stat_grid.set_margin_top(4)
        self._ov_stat_avg = self._make_stat_card('—', 'Avg life (active)', tooltip=FULL_EQUIV_TOOLTIP)
        self._ov_stat_best = self._make_stat_card('—', 'Best session')
        self._ov_stat_worst = self._make_stat_card('—', 'Worst session', tooltip=FULL_EQUIV_TOOLTIP)
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
        self._est_chart_card.pack_start(_capped_image_wrapper(self._est_chart_image), False, False, 0)
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
        self._detail_title.set_line_wrap(True)
        self._detail_title.set_max_width_chars(18)
        self._detail_subtitle = _label('', css_class=None)
        self._detail_subtitle.set_name('detail-subtitle')
        self._detail_subtitle.set_line_wrap(True)
        self._detail_subtitle.set_max_width_chars(20)
        text_box.pack_start(self._detail_title,    False, False, 0)
        text_box.pack_start(self._detail_subtitle, False, False, 0)

        self._detail_header.pack_start(icon_box, False, False, 0)
        self._detail_header.pack_start(text_box, True, True, 0)

        self._detail_lag_note = _label('Data may lag several minutes', css_class=None)
        self._detail_lag_note.set_valign(Gtk.Align.CENTER)
        self._detail_lag_note.set_line_wrap(True)
        self._detail_lag_note.set_max_width_chars(16)
        _set_color(self._detail_lag_note, SUBTEXT)
        self._detail_lag_note.set_no_show_all(True)
        self._detail_lag_note.hide()
        self._detail_header.pack_end(self._detail_lag_note, False, False, 0)

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
        self._detail_equiv_card = self._make_stat_card('—', 'Full-charge equiv. (active)', tooltip=FULL_EQUIV_TOOLTIP)
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
        self._detail_chart_card = _box(spacing=4)
        self._detail_chart_card.get_style_context().add_class('chart-card')
        self._detail_chart_card.set_margin_top(4)

        chart_hdr_row = _box(Gtk.Orientation.HORIZONTAL, 8)
        self._detail_chart_lbl = _label('Battery level over time', 'chart-label')
        chart_hdr_row.pack_start(self._detail_chart_lbl, True, True, 0)
        self._detail_chart_hover_lbl = _label('', 'chart-label')
        self._detail_chart_hover_lbl.set_xalign(1.0)
        chart_hdr_row.pack_start(self._detail_chart_hover_lbl, False, False, 0)
        self._detail_chart_card.pack_start(chart_hdr_row, False, False, 0)

        # Chart style toggle — per-session (persisted in chart_prefs.json,
        # keyed by session start_ts), not an app-wide setting: each session
        # can use whichever of line/bar (and, for bar, bucket size) suits it.
        style_row = _box(Gtk.Orientation.HORIZONTAL, 6)
        self._style_line_btn = Gtk.Button(label='Line')
        self._style_bar_btn  = Gtk.Button(label='Bar')
        self._style_line_btn.get_style_context().add_class('style-toggle')
        self._style_bar_btn.get_style_context().add_class('style-toggle')
        self._style_line_btn.connect('clicked', lambda _b: self._set_chart_style('line'))
        self._style_bar_btn.connect('clicked', lambda _b: self._set_chart_style('bar'))
        style_row.pack_start(self._style_line_btn, False, False, 0)
        style_row.pack_start(self._style_bar_btn, False, False, 0)

        self._gran_box = _box(Gtk.Orientation.HORIZONTAL, 4)
        self._gran_btns = {}
        for gh in GRANULARITY_CHOICES_H:
            gbtn = Gtk.Button(label=f'{gh}h')
            gbtn.get_style_context().add_class('style-toggle')
            gbtn.connect('clicked', lambda _b, gh=gh: self._set_chart_granularity(gh))
            self._gran_btns[gh] = gbtn
            self._gran_box.pack_start(gbtn, False, False, 0)
        style_row.pack_start(self._gran_box, False, False, 10)
        self._detail_chart_card.pack_start(style_row, False, False, 2)

        # Long-idle badge — only shown when the session's chart condenses a
        # 24h+ gap (see LONG_GAP_THRESHOLD_S / _compress_xs), to carry the
        # context the compressed axis can no longer show at-a-glance.
        self._detail_gap_badge = _label('', 'sleep-note')
        self._detail_gap_badge.set_line_wrap(True)
        self._detail_gap_badge.set_xalign(0)
        self._detail_gap_badge_box = _box(spacing=0)
        self._detail_gap_badge_box.set_margin_bottom(6)
        self._detail_gap_badge_box.pack_start(self._detail_gap_badge, False, False, 0)
        self._detail_gap_badge_box.set_no_show_all(True)
        self._detail_chart_card.pack_start(self._detail_gap_badge_box, False, False, 0)

        self._detail_chart_image = Gtk.Image()
        # Gtk.Image has no window of its own, so events must go through an
        # EventBox — add_events() doesn't reliably work directly on a bare
        # Image. The readout only appears when hovering close to an actual
        # data point (not anywhere along the axes), shown via the fixed
        # corner label rather than a floating popup — a real tooltip/overlay
        # popup near the cursor kept interfering with further events.
        chart_event_box = Gtk.EventBox()
        chart_event_box.add(self._detail_chart_image)
        chart_event_box.add_events(
            Gdk.EventMask.POINTER_MOTION_MASK | Gdk.EventMask.LEAVE_NOTIFY_MASK)
        chart_event_box.connect('motion-notify-event', self._on_chart_motion)
        chart_event_box.connect('leave-notify-event', self._on_chart_leave)
        self._detail_chart_meta = None
        self._detail_chart_card.pack_start(_capped_image_wrapper(chart_event_box), False, False, 0)
        body.pack_start(self._detail_chart_card, False, False, 4)

        # Points recorded, with a toggle for showing markers on the chart
        points_row = _box(Gtk.Orientation.HORIZONTAL, 8)
        points_row.set_margin_top(4)
        self._detail_points_card = self._make_stat_card('—', 'Data points recorded')
        points_row.pack_start(self._detail_points_card, True, True, 0)

        self._show_points_check = Gtk.CheckButton(label='Show points')
        self._show_points_check.set_valign(Gtk.Align.CENTER)
        self._show_points_check.connect('toggled', self._on_toggle_show_points)
        points_row.pack_start(self._show_points_check, False, False, 0)

        body.pack_start(points_row, False, False, 0)

        sw.add(body)
        box.pack_start(sw, True, True, 0)
        return box

    # ── CHARGING PAGE (temporary, live-only) ────────────────────────────────

    def _build_charging_page(self):
        box = _box(spacing=0)

        header = _box(Gtk.Orientation.HORIZONTAL, 16)
        header.set_name('detail-header')
        icon = _label('⚡', xalign=0.5)
        icon.set_halign(Gtk.Align.CENTER)
        header.pack_start(icon, False, False, 0)

        text_box = _box(spacing=2)
        self._charging_title = _label('Charging', css_class=None)
        self._charging_title.set_name('detail-title')
        self._charging_title.set_xalign(0)
        _set_color(self._charging_title, GREAT)
        self._charging_subtitle = _label('', css_class=None)
        self._charging_subtitle.set_name('detail-subtitle')
        self._charging_subtitle.set_xalign(0)
        self._charging_subtitle.set_line_wrap(True)
        text_box.pack_start(self._charging_title, False, False, 0)
        text_box.pack_start(self._charging_subtitle, False, False, 0)
        header.pack_start(text_box, True, True, 0)
        box.pack_start(header, False, False, 0)

        sw = _scrolled()
        body = _box(spacing=0)
        body.set_margin_start(24)
        body.set_margin_end(24)
        body.set_margin_top(16)
        body.set_margin_bottom(20)

        grid = Gtk.Grid()
        grid.set_column_homogeneous(True)
        self._charging_pct_card  = self._make_stat_card('—', 'Current charge', color=GREAT)
        self._charging_rate_card = self._make_stat_card('—', 'Charge rate')
        self._charging_eta_card  = self._make_stat_card('—', 'Time to full')
        grid.attach(self._charging_pct_card,  0, 0, 1, 1)
        grid.attach(self._charging_rate_card, 1, 0, 1, 1)
        grid.attach(self._charging_eta_card,  2, 0, 1, 1)
        body.pack_start(grid, False, False, 4)

        self._charging_chart_card = _box(spacing=4)
        self._charging_chart_card.get_style_context().add_class('chart-card')
        self._charging_chart_card.set_margin_top(8)
        self._charging_chart_card.pack_start(
            _label('Charge % over time (live)', 'chart-label'), False, False, 0)
        self._charging_chart_image = Gtk.Image()
        self._charging_chart_card.pack_start(
            _capped_image_wrapper(self._charging_chart_image), False, False, 0)
        body.pack_start(self._charging_chart_card, False, False, 4)

        note = _label(
            "This card is temporary — it disappears once you unplug and "
            "isn't saved to session history.", 'sleep-note')
        note.set_line_wrap(True)
        note.set_xalign(0)
        note.set_margin_top(8)
        body.pack_start(note, False, False, 0)

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

    def _make_stat_card(self, val, lbl, color=None, tooltip=None):
        card = _box(spacing=2)
        card.get_style_context().add_class('stat-card')
        if tooltip:
            card.set_tooltip_text(tooltip)
        val_lbl = _label(val, 'stat-card-val')
        if color:
            _set_color(val_lbl, color)
        lbl_lbl = _label(lbl, 'stat-card-lbl')
        # Let the label wrap instead of forcing the card's full single-line
        # text width — that was the main driver of the app's oversized real
        # minimum width (it silently overrode set_size_request everywhere)
        lbl_lbl.set_line_wrap(True)
        lbl_lbl.set_max_width_chars(10)
        lbl_lbl.set_justify(Gtk.Justification.CENTER)
        lbl_lbl.set_halign(Gtk.Align.CENTER)
        val_lbl.set_halign(Gtk.Align.CENTER)
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
        self._sessions, self._charging = _read_upower_history()
        self._bat_info    = get_battery_info()
        self._hidden_idxs = resolve_hidden_idxs(self._sessions, self._hidden_ts)
        self._refresh_sidebar()
        self._refresh_overview()
        self._refresh_charging_card()

        active_s = next((s for s in self._sessions if s.get('active')), None)
        had_active_before = self._had_active
        self._had_active = active_s is not None

        if self._charging_selected:
            # Keep the live charging detail view current, or fall back to
            # Overview the moment it's unplugged and the card disappears
            if self._is_charging():
                self._show_charging_detail()
            else:
                self._charging_selected = False
                self._stack.set_visible_child_name('overview')
                self._refresh_overview()
        elif self._selected_idx is not None:
            # If the selected session is the active one, refresh its detail view too
            s = self._sessions[self._selected_idx] if self._selected_idx < len(self._sessions) else None
            if s and s.get('active'):
                self._show_session_detail(self._selected_idx)
        elif active_s and not had_active_before:
            # A session just became active (e.g. upowerd caught up after a
            # charge cycle) — jump to it instead of leaving the user on Overview
            self._show_session_detail(self._sessions.index(active_s))
        return True  # keep GLib.timeout running

    # ── LIVE POWER SIGNALS (event-driven, instant plug/unplug detection) ────

    def _setup_live_power_signals(self):
        """Subscribe to UPower's D-Bus PropertiesChanged signal on the
        battery and AC/line-power devices, so the app reacts the instant the
        OS notices a plug/unplug or charge-state change instead of waiting
        for the next poll. Silently does nothing if D-Bus/upowerd isn't
        reachable (e.g. a sandboxed environment) — the _auto_refresh poll
        timer still covers that case, just with more latency."""
        try:
            bus = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)
            proxy = Gio.DBusProxy.new_sync(
                bus, Gio.DBusProxyFlags.NONE, None,
                'org.freedesktop.UPower', '/org/freedesktop/UPower',
                'org.freedesktop.UPower', None)
            devices = proxy.call_sync(
                'EnumerateDevices', None, Gio.DBusCallFlags.NONE, -1, None).unpack()[0]
            watched = [p for p in devices if '/battery_' in p or '/line_power_' in p]
            for path in watched:
                bus.signal_subscribe(
                    'org.freedesktop.UPower', 'org.freedesktop.DBus.Properties',
                    'PropertiesChanged', path, None,
                    Gio.DBusSignalFlags.NONE, self._on_power_signal)
        except GLib.Error:
            pass

    def _on_power_signal(self, *_args):
        # Debounce — a single plug/unplug can fire PropertiesChanged on
        # several properties and/or both devices in quick succession.
        if self._live_refresh_debounce_id is not None:
            GLib.source_remove(self._live_refresh_debounce_id)
        self._live_refresh_debounce_id = GLib.timeout_add(400, self._live_refresh_now)

    def _live_refresh_now(self):
        self._live_refresh_debounce_id = None
        self._load_data()
        return False  # one-shot

    def _auto_refresh(self):
        """Called every 300s as a fallback safety net (the D-Bus signal
        subscription above is the primary trigger) — reloads while there's
        an active session, while the OS reports discharging but upowerd
        hasn't logged it yet, or while charging (to keep the live charging
        card current).

        Checks a fresh get_battery_info() rather than the cached
        self._bat_info — that cache is only ever updated by _load_data()
        itself, so gating on it means a state change that happens while the
        app is sitting idle (e.g. plugging in after being fully idle) never
        flips the condition true and _load_data() never gets called again."""
        has_active = any(s.get('active') for s in self._sessions)
        live_status = (get_battery_info() or {}).get('status', '').lower()
        if has_active or live_status in ('charging', 'discharging', 'not charging'):
            self._load_data()
        return True  # keep timer alive

    def _on_scale_factor_changed(self, *_args):
        """Display moved to a different-DPI monitor — recompute chart
        resolution and force a redraw in case the compositor delivered the
        real scale after the first frame was already painted (causes blur)."""
        self._dpi = int(min(2.2, self.get_scale_factor() or 1) * 120)
        self.queue_draw()
        self._schedule_chart_rerender()

    def _on_window_configure(self, widget, event):
        """Window resized or tiled — re-render charts to fit, debounced so a
        drag-resize doesn't trigger a matplotlib render on every frame."""
        self._schedule_chart_rerender()
        return False

    def _schedule_chart_rerender(self):
        if self._resize_debounce_id is not None:
            GLib.source_remove(self._resize_debounce_id)
        self._resize_debounce_id = GLib.timeout_add(200, self._rerender_visible_charts)

    def _rerender_visible_charts(self):
        self._resize_debounce_id = None
        if self._selected_idx is not None:
            self._show_session_detail(self._selected_idx)
        else:
            self._refresh_overview()
        return False  # one-shot

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
        # Ellipsize instead of forcing the row's full "3:54 PM - 10:03 PM"
        # width — this and the sparkline below were the two biggest
        # contributors to the sidebar's oversized real minimum width
        time_lbl.set_ellipsize(Pango.EllipsizeMode.END)
        time_lbl.set_width_chars(8)
        left.pack_start(date_lbl, False, False, 0)
        left.pack_start(time_lbl, False, False, 0)
        inner.pack_start(left, True, True, 0)

        # Sparkline
        try:
            pb = make_sparkline_pixbuf(s)
            if pb:
                h = 18
                w = int(pb.get_width() * h / pb.get_height())
                pb_scaled = pb.scale_simple(w, h, GdkPixbuf.InterpType.BILINEAR)
                spark_img = Gtk.Image.new_from_pixbuf(pb_scaled)
                inner.pack_start(spark_img, False, False, 0)
        except Exception:
            pass

        # Duration
        right = _box(spacing=1)
        right.set_halign(Gtk.Align.END)
        dur_lbl = _label(fmt_duration(s.get('active_h', s['duration_h'])), 'session-duration')
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

        # Live-discharging banner (covers the gap before upowerd logs the first
        # history sample of a new session, e.g. right after a charge cycle)
        live_discharging = bool(self._bat_info) and \
            self._bat_info.get('status', '').lower() == 'discharging'
        if live_discharging and not active_sessions:
            self._live_discharge_banner.show()
        else:
            self._live_discharge_banner.hide()

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
            self._no_data_box.show_all()
            self._overview_chart_card.hide()
            self._ov_stat_grid.hide()
            self._estimate_panel.hide()
            return

        self._no_data_box.hide()

        # Overview bar chart (show when there are completed sessions)
        if completed:
            pb = make_overview_pixbuf(visible, self._dpi)
            if pb:
                w = _chart_width(self._overview_chart_card)
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
            w = _chart_width(self._est_chart_card)
            h = int(pb.get_height() * w / pb.get_width())
            scaled = pb.scale_simple(w, h, GdkPixbuf.InterpType.BILINEAR)
            self._est_chart_image.set_from_pixbuf(scaled)

    def _on_toggle_show_points(self, btn):
        self._show_data_points = btn.get_active()
        if self._selected_idx is not None:
            self._show_session_detail(self._selected_idx)

    def _chart_point_at(self, x, y):
        """Map a cursor position (relative to the chart EventBox — the same
        space the Gtk.Image inside it occupies) to the nearest data point.
        Returns (nearest_point, point_px, point_py) or None if the cursor is
        outside the plotted axes area. Uses the pixbuf's own dimensions
        rather than the widget's allocation — the wrapping ScrolledWindow
        can allocate the image more space than its pixbuf's natural size and
        center it, which would otherwise throw off the bbox-fraction math."""
        meta = self._detail_chart_meta
        pb = self._detail_chart_image.get_pixbuf()
        if not meta or not pb:
            return None
        pb_w, pb_h = pb.get_width(), pb.get_height()
        off_x = (self._detail_chart_image.get_allocated_width() - pb_w) / 2
        off_y = (self._detail_chart_image.get_allocated_height() - pb_h) / 2
        px, py = x - off_x, y - off_y

        bx0, by0, bx1, by1 = meta['bbox']
        ax0, ax1 = bx0 * pb_w, bx1 * pb_w
        ay0, ay1 = (1 - by1) * pb_h, (1 - by0) * pb_h
        if not (ax0 <= px <= ax1 and ay0 <= py <= ay1):
            return None

        xlo, xhi = meta['xlim']
        ylo, yhi = meta['ylim']

        def to_px(pt):
            t, pct, _ = pt
            pt_x = off_x + ax0 + (t - xlo) / (xhi - xlo) * (ax1 - ax0)
            pt_y = off_y + ay0 + (yhi - pct) / (yhi - ylo) * (ay1 - ay0)
            return pt_x, pt_y

        # Nearest by actual on-screen distance, not just time (x) distance —
        # sessions with sleep gaps have long stretches of chart width with
        # only two real points bracketing many hours, and picking "nearest
        # in time" alone can point at a spot far from the cursor on screen
        # whenever the line is steep or the two points aren't evenly spaced.
        best_pt, best_px, best_dist = None, None, None
        for pt in meta['points']:
            cand_px = to_px(pt)
            d = (cand_px[0] - x) ** 2 + (cand_px[1] - y) ** 2
            if best_dist is None or d < best_dist:
                best_pt, best_px, best_dist = pt, cand_px, d
        return best_pt, best_px[0], best_px[1]

    def _on_chart_motion(self, widget, event):
        hit = self._chart_point_at(event.x, event.y)
        if not hit:
            self._detail_chart_hover_lbl.set_text('')
            return False
        nearest, point_px, point_py = hit
        # Only show it when actually close to the point itself, not just
        # anywhere in line with it on the x-axis.
        dist = ((event.x - point_px) ** 2 + (event.y - point_py) ** 2) ** 0.5
        if dist > 14:
            self._detail_chart_hover_lbl.set_text('')
            return False
        self._detail_chart_hover_lbl.set_text(f'{nearest[2]} — {nearest[1]:.0f}%')
        return False

    def _on_chart_leave(self, widget, event):
        self._detail_chart_hover_lbl.set_text('')
        return False

    def _set_chart_style(self, style):
        if self._selected_idx is None:
            return
        s = self._sessions[self._selected_idx]
        key = str(int(s['start_ts']))
        pref = dict(get_chart_pref(self._chart_prefs, s))
        pref['style'] = style
        self._chart_prefs[key] = pref
        save_chart_prefs(self._chart_prefs)
        self._show_session_detail(self._selected_idx)

    def _set_chart_granularity(self, granularity_h):
        if self._selected_idx is None:
            return
        s = self._sessions[self._selected_idx]
        key = str(int(s['start_ts']))
        pref = dict(get_chart_pref(self._chart_prefs, s))
        pref['granularity_h'] = granularity_h
        self._chart_prefs[key] = pref
        save_chart_prefs(self._chart_prefs)
        self._show_session_detail(self._selected_idx)

    def _refresh_chart_style_controls(self, pref):
        is_bar = pref['style'] == 'bar'
        for btn, active in ((self._style_line_btn, not is_bar),
                            (self._style_bar_btn, is_bar)):
            ctx = btn.get_style_context()
            (ctx.add_class if active else ctx.remove_class)('style-toggle-active')
        self._gran_box.set_visible(is_bar)
        for gh, gbtn in self._gran_btns.items():
            ctx = gbtn.get_style_context()
            active = is_bar and gh == pref.get('granularity_h', 1)
            (ctx.add_class if active else ctx.remove_class)('style-toggle-active')
        # "Show points" only means anything for the line chart's markers
        self._show_points_check.set_visible(not is_bar)

    def _show_session_detail(self, idx):
        if idx < 0 or idx >= len(self._sessions):
            return
        s = self._sessions[idx]
        self._selected_idx = idx
        self._charging_selected = False
        color = RATING_COLORS.get(
            'active' if s.get('active') else s['usage_rating'], GOOD)

        # Header
        active_h = s.get('active_h', s['duration_h'])
        idle_h   = max(0, s['duration_h'] - active_h)
        self._detail_title.set_markup(
            f'<span color="{color}" weight="heavy" size="x-large">{fmt_duration(active_h)}</span>'
            f'<span size="small" color="{SUBTEXT}"> screen on</span>'
            f'   <span color="{SUBTEXT}" weight="heavy" size="x-large">{fmt_duration(idle_h)}</span>'
            f'<span size="small" color="{SUBTEXT}"> idle</span>')

        # Date string
        if s['start'].date() != s['end'].date():
            date_str = (s['start'].strftime('%b %-d') + ' – ' +
                        s['end'].strftime('%b %-d, %Y'))
        else:
            date_str = s['start'].strftime('%A, %B %-d, %Y')
        time_str = f'{s["start"].strftime("%-I:%M %p")} – {s["end"].strftime("%-I:%M %p")}'
        self._detail_subtitle.set_text(f'{date_str} · {time_str}')

        if s.get('active'):
            self._detail_lag_note.show()
        else:
            self._detail_lag_note.hide()

        # Sleep note
        sleep_count = len(s.get('sleep_gaps', []))
        if sleep_count > 0:
            note = (f'{sleep_count} sleep period{"s" if sleep_count > 1 else ""} detected.  '
                    f'Full-charge equivalent calculated from active time only.')
            self._sleep_note.set_text(note)
            self._sleep_note_box.show_all()
        else:
            self._sleep_note_box.hide()

        # Long-idle badge — the largest 24h+ gap, if any (mirrors the
        # condensing done on the chart itself in make_detail_pixbuf).
        long_gaps = [g for g in s.get('sleep_gaps', [])
                     if g[1] - g[0] > LONG_GAP_THRESHOLD_S]
        if long_gaps:
            ts_prev, ts_next, val_prev = max(long_gaps, key=lambda g: g[1] - g[0])
            gap_h = (ts_next - ts_prev) / 3600
            self._detail_gap_badge.set_text(
                f'↳ resumed after {_fmt_gap_duration(gap_h)} idle · was {round(val_prev)}%')
            self._detail_gap_badge_box.show_all()
        else:
            self._detail_gap_badge_box.hide()

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

        # Chart style — per-session choice (line vs bar, + bar granularity)
        pref = get_chart_pref(self._chart_prefs, s)
        self._refresh_chart_style_controls(pref)

        # Chart label
        chart_lbl = 'Battery level over time'
        if pref['style'] == 'line' and sleep_count > 0:
            chart_lbl += '  ·  - - - = sleeping'
        self._detail_chart_lbl.set_text(chart_lbl)

        # Chart (in thread to avoid blocking UI)
        chart_w = _chart_width(self._detail_chart_card)
        show_points = self._show_data_points
        def render_chart():
            if pref['style'] == 'bar':
                pb, meta = make_detail_bar_pixbuf(
                    s, granularity_h=pref.get('granularity_h', 1), dpi=self._dpi)
            else:
                pb, meta = make_detail_pixbuf(s, self._dpi, show_points=show_points)
            def update():
                if pb:
                    h = int(pb.get_height() * chart_w / pb.get_width())
                    scaled = pb.scale_simple(chart_w, h, GdkPixbuf.InterpType.BILINEAR)
                    self._detail_chart_image.set_from_pixbuf(scaled)
                    self._detail_chart_meta = meta
                return False
            GLib.idle_add(update)
        threading.Thread(target=render_chart, daemon=True).start()

        # Points
        self._detail_points_card._val_lbl.set_text(str(len(s['points'])))

        self._stack.set_visible_child_name('detail')

    # ── CHARGING CARD (live-only, never saved to history) ───────────────────

    def _is_charging(self):
        """True whenever AC is connected and the battery is being actively
        managed — covers both 'charging' and 'not charging'. The kernel only
        reports 'not charging' while a charger is present but paused (a
        charge-limit/battery-saver cap, thermal throttling, calibration,
        etc.) — a genuine unplug always reports 'discharging' instead, so
        this never mistakes "actually unplugged" for "still connected"."""
        if not self._bat_info:
            return False
        return self._bat_info.get('status', '').lower() in ('charging', 'not charging')

    def _charging_display(self):
        """Badge/pct/rate/sub/eta text for the current live charging state,
        shared by the sidebar card and the detail page so their wording
        can't drift apart. Three cases: actively charging with upower-log
        data to compute a rate from; just plugged in with no log data yet;
        or paused/holding (e.g. at a charge-saver cap) with AC still
        connected but the kernel reporting 'not charging'."""
        cap = (self._bat_info or {}).get('capacity')
        status = (self._bat_info or {}).get('status', '').lower()
        c = self._charging

        if c:
            pct = f"{c['current_pct']}%"
            rate = c['rate_pct_per_h']
            rate_text = f"+{rate:.1f}%/hr" if rate > 0 else ''
            mins = max(0, int((time.time() - c['start_ts']) / 60))
            ago = f"{mins}m ago" if mins < 60 else f"{mins // 60}h {mins % 60}m ago"
            if rate > 0 and c['current_pct'] < 100:
                eta_h = (100 - c['current_pct']) / rate
                eta = f"~{fmt_duration(eta_h)}"
                sub = f"Plugged in {ago} · full in {eta}"
            else:
                eta = '—'
                sub = f"Plugged in {ago}"
            return dict(badge='⚡ CHARGING', pct=pct, rate=rate_text, sub=sub, eta=eta)

        pct = f"{cap}%" if cap else '—'
        if status == 'not charging':
            return dict(badge='⏸ PLUGGED IN', pct=pct, rate='',
                        sub=f"Holding at {pct} — not currently charging", eta='—')
        return dict(badge='⚡ CHARGING', pct=pct, rate='',
                    sub='Just plugged in — gathering data…', eta='—')

    def _refresh_charging_card(self):
        """Show/hide the sidebar's temporary charging card and keep its
        numbers current. Called on every _load_data() refresh."""
        if not self._is_charging():
            self._charging_revealer.set_reveal_child(False)
            return

        self._charging_revealer.set_reveal_child(True)
        d = self._charging_display()
        self._charge_badge_lbl.set_text(d['badge'])
        self._charge_pct_lbl.set_text(d['pct'])
        self._charge_rate_lbl.set_text(d['rate'])
        self._charge_sub_lbl.set_text(d['sub'])

    def _show_charging_detail(self):
        if not self._is_charging():
            return
        self._selected_idx = None
        self._charging_selected = True

        d = self._charging_display()
        self._charging_title.set_text('Plugged In' if d['badge'].startswith('⏸') else 'Charging')
        self._charging_subtitle.set_text(d['sub'])
        self._charging_pct_card._val_lbl.set_text(d['pct'])
        self._charging_rate_card._val_lbl.set_text(d['rate'] or '—')
        self._charging_eta_card._val_lbl.set_text(d['eta'])

        c = self._charging
        if c:
            self._charging_chart_card.show()
            chart_w = _chart_width(self._charging_chart_card)
            def render_chart():
                pb = make_charging_pixbuf(c, self._dpi)
                def update():
                    if pb:
                        h = int(pb.get_height() * chart_w / pb.get_width())
                        scaled = pb.scale_simple(chart_w, h, GdkPixbuf.InterpType.BILINEAR)
                        self._charging_chart_image.set_from_pixbuf(scaled)
                    return False
                GLib.idle_add(update)
            threading.Thread(target=render_chart, daemon=True).start()
        else:
            self._charging_chart_card.hide()

        self._stack.set_visible_child_name('charging')

    # ── TAB SWITCHING ─────────────────────────────────────────────────────────

    def _switch_tab(self, name):
        self._tab_overview.get_style_context().add_class('tab-btn-active')
        if name == 'overview':
            self._selected_idx = None
            self._charging_selected = False
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
            dur_lbl = _label(fmt_duration(s.get('active_h', s['duration_h'])), css_class=None)
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
                              btn, latest, notes, installer_url, None)
            except Exception as e:
                GLib.idle_add(self._show_update_result, btn, None, None, None, str(e))

        threading.Thread(target=check, daemon=True).start()

    def _show_update_result(self, btn, latest, notes, installer_url, error):
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
cat > "$DESKTOP_DIR/io.github.filoviridae.batterylens.desktop" << EOF
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
echo -e "     rm -rf $APP_DIR $LAUNCHER $DESKTOP_DIR/io.github.filoviridae.batterylens.desktop $ICON_THEME_FILE"
echo ""
