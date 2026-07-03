#!/usr/bin/env python3
"""
BatteryLens - GTK3 native battery charge history viewer
Version: 1.1.2
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
matplotlib.use('cairo')
import matplotlib.pyplot as plt
import matplotlib.patches as mpatches
import numpy as np
from matplotlib.backends.backend_cairo import FigureCanvasCairo, RendererCairo
from matplotlib.ticker import FuncFormatter, MaxNLocator

# Must match the installed .desktop file's basename so GNOME Shell (Wayland
# app_id lookup) and window managers (X11 WM_CLASS) resolve the right icon
# instead of falling back to the Python interpreter's icon.
GLib.set_prgname('io.github.filoviridae.batterylens')
GLib.set_application_name('BatteryLens')

VERSION = "1.1.2"
REPO = "Filoviridae/batterylens"
SLEEP_GAP_THRESHOLD_S = 900  # 15 min

APP_DIR   = os.path.expanduser('~/.local/share/batterylens')
HIDDEN_FILE = os.path.join(APP_DIR, 'hidden_sessions.json')
UNKNOWN_STATES_FILE = os.path.join(APP_DIR, 'unknown_states.json')
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

def _smart_xticks(ax, max_h):
    # Smaller candidates matter for a freshly-started active session, which
    # might only have ~1 hour (or less) of data. Pick whichever step lands
    # the tick count closest to the middle of a 4-9 tick sweet spot, rather
    # than the first exact match — consecutive candidates' [4,9]-tick windows
    # don't all overlap (e.g. 0.1h and 0.25h leave a gap around 0.9-1.0h), so
    # "first match, else 24h" used to silently fall through to a useless
    # single "0h, 24h" tick pair for durations landing in one of those gaps.
    nice = [0.05, 0.1, 0.25, 0.5, 1, 2, 3, 4, 6, 8, 12, 24]
    step = min(nice, key=lambda s: abs(max_h / s - 6))
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
    xs  = [(p['ts'] - pts[0]['ts']) / 3600 for p in pts]
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
    _smart_xticks(ax, max(xs))
    plt.tight_layout(pad=0.4)
    bbox = ax.get_position()
    pb = _fig_to_pixbuf(fig, dpi, tight=False)
    plt.close(fig)

    meta = {
        'bbox': (bbox.x0, bbox.y0, bbox.x1, bbox.y1),
        'xlim': xlim,
        'ylim': ylim,
        'points': [
            ((p['ts'] - pts[0]['ts']) / 3600, p['val'],
             datetime.datetime.fromtimestamp(p['ts']).strftime('%-I:%M %p'))
            for p in pts
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
    xs   = [(p['ts'] - pts[0]['ts']) / 3600 for p in pts]
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
        chart_w = _chart_width(self._detail_chart_card)
        show_points = self._show_data_points
        def render_chart():
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

