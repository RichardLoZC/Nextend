#!/usr/bin/env python3
"""Plot recorded desktop-capture metrics. Optional dependency: matplotlib."""
import argparse
import json
import os
from pathlib import Path

root = Path(__file__).resolve().parent.parent
os.environ.setdefault('MPLCONFIGDIR', str(root / 'work/matplotlib-cache'))
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--report', type=Path, default=root / 'outputs/benchmarks/usb-native-60-30min.json')
parser.add_argument('--resources', type=Path, default=root / 'outputs/benchmarks/usb-native-60-30min-resources.json')
parser.add_argument('--output', type=Path, default=root / 'outputs/稳定性曲线.png')
args = parser.parse_args()
report = json.loads(args.report.read_text())
resources = json.loads(args.resources.read_text())
rows = report['samples']
minutes = [r['seconds'] / 60 for r in rows]
duration = minutes[-1]

plt.rcParams.update({'font.family': 'DejaVu Sans', 'font.size': 11,
                     'axes.spines.top': False, 'axes.spines.right': False,
                     'axes.edgecolor': '#CBD5E1', 'axes.labelcolor': '#334155',
                     'xtick.color': '#475569', 'ytick.color': '#475569'})
fig, axes = plt.subplots(3, 1, figsize=(12, 9), sharex=True)
fig.patch.set_facecolor('white')
fig.subplots_adjust(top=.84, bottom=.12, left=.09, right=.97, hspace=.3)
fig.text(.09, .95, 'PadBridge | USB desktop capture', size=22, weight='bold', color='#0F172A')
fig.text(.09, .91, f"{report['width']} × {report['height']}  ·  {report['targetFps']} fps target  ·  {report['codec'].upper()}  ·  {duration:.1f} minutes", color='#475569', size=13)
fig.text(.09, .875, 'M4 MacBook Air → Xiaomi Pad 7 Ultra   |   2026-10-16', color='#64748B', size=11)

axes[0].plot(minutes, [r['encodeFps'] for r in rows], color='#0F766E', lw=1.2, label='Mac encoded fps')
axes[0].plot(minutes, [r.get('renderFps', float('nan')) for r in rows], color='#2563EB', alpha=.7, lw=.8, label='Pad rendered callbacks/s')
axes[0].axhline(report['targetFps'], color='#94A3B8', ls='--', lw=1, label='Target')
axes[0].set_ylabel('Frames / second')
axes[0].set_ylim(0, max(report['targetFps'] * 1.18, 70))

axes[1].plot(minutes, [r['captureToDecodeAckP50Ms'] for r in rows], color='#0891B2', lw=1.2, label='Rolling P50')
axes[1].plot(minutes, [r['captureToDecodeAckP95Ms'] for r in rows], color='#EA580C', lw=1.2, label='Rolling P95')
axes[1].set_ylabel('Decode ACK round trip (ms)')
axes[1].set_ylim(bottom=0)

for key, label, color in [('macRssMB', 'Mac process RSS', '#7C3AED'), ('padPssMB', 'Pad process PSS', '#0F766E')]:
    points = [r for r in resources['samples'] if key in r]
    axes[2].plot([r['elapsedSeconds'] / 60 for r in points], [r[key] for r in points], color=color, lw=1.5, marker='o' if key == 'padPssMB' else None, markersize=3, label=label)
axes[2].set_ylabel('Memory (MB)')
axes[2].set_ylim(bottom=0)
axes[2].set_xlabel('Elapsed minutes')
for ax in axes:
    ax.set_xlim(0, duration)
    ax.grid(axis='y', color='#E2E8F0', linewidth=.7)
    ax.legend(loc='lower right', frameon=True, facecolor='white', framealpha=.92, fontsize=9)

fig.text(.09, .045, 'Frame callbacks are not physical scan-out measurements. ACK latency includes the return transport.', color='#64748B', size=9)
fig.text(.09, .025, 'Latency percentiles use up to 6,000 recent frames. RSS and PSS are different memory accounting measures.', color='#64748B', size=9)
args.output.parent.mkdir(parents=True, exist_ok=True)
fig.savefig(args.output, dpi=160, facecolor='white')
plt.close(fig)
print(args.output)
