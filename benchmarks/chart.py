#!/usr/bin/env python3
"""Draw the README's bar charts from benchmarks/results.json, in light and dark.

    python3 -I benchmarks/chart.py

Each row has its own scale, because the rows are measured in different units, so compare the bars
within a row. A bar is never drawn shorter than MIN_BAR, so a tiny value stays visible and clickable.
"""
import json
from html import escape
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
THEMES = {
    "light": {"surface": "#fcfcfb", "border": "#e4e3df", "ink": "#0b0b0b", "soft": "#52514e", "muted": "#74736e",
              "ucu": "#2a78d6", "Codex engine": "#eb6834", "agent-desktop": "#1baf7a"},
    "dark": {"surface": "#1a1a19", "border": "#383835", "ink": "#f0efec", "soft": "#c3c2b7", "muted": "#9a998f",
             "ucu": "#3987e5", "Codex engine": "#d95926", "agent-desktop": "#199e70"},
}
FONT = "-apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif"
WIDTH, LEFT, BAR_MAX, BAR_HEIGHT, BAR_GAP, ROW_GAP = 860, 236, 440, 14, 3, 22
MIN_BAR = 6


def ms(value):
    return f"{value / 1000:.1f} s" if value >= 1000 else f"{value:.0f} ms"


def count(value):
    return f"{value:,.0f}"


def rows_speed(results):
    m = results["medians"]
    tools = ["ucu", "Codex engine", "agent-desktop"]

    def row(label, note, metric, extra=()):
        return label, note, [(tool, tool, m[tool][metric], ms(m[tool][metric])) for tool in tools] + list(extra)

    skeleton = m["agent-desktop skeleton"]["read dense app (ms)"]
    return [
        row("Read a small window", "Calculator", "read small app (ms)"),
        row("Click a button", "Calculator", "click (ms)"),
        row("Take a screenshot", "Calculator", "screenshot (ms)"),
        row("Finish a task", "12 + 34 = in Calculator", "task (ms)"),
        row("Read a large window", "Font Book", "read dense app (ms)",
            [("agent-desktop", "agent-desktop, outline only", skeleton, ms(skeleton))]),
        row("Start from nothing", "first read after launch", "cold start (ms)"),
    ]


def rows_tokens(results):
    m, setup, sizes = results["medians"], results["setup chars"], results["sizes"]
    tools = ["ucu", "Codex engine", "agent-desktop"]
    task = {tool: m[tool]["task tokens read"] + m[tool]["task tokens written"] for tool in tools}
    small = {tool: sizes[tool]["read small app (chars)"] / 4 for tool in tools}
    dense = {tool: m[tool]["read dense app (chars)"] / 4 for tool in tools}
    session = {tool: sum(setup[tool].values()) / 4 for tool in tools}
    memory = results["idle memory (MB)"]
    outline = m["agent-desktop skeleton"]["read dense app (chars)"] / 4
    return [
        ("Finish a task", "12 + 34 = in Calculator", [(t, t, task[t], f"{count(task[t])} tokens") for t in tools]),
        ("Read a small window", "Calculator", [(t, t, small[t], f"{count(small[t])} tokens") for t in tools]),
        ("Read a large window", "Font Book", [(t, t, dense[t], f"{count(dense[t])} tokens") for t in tools]
         + [("agent-desktop", "agent-desktop, outline only", outline, f"{count(outline)} tokens")]),
        ("Set up a session", "tool definitions, rules, docs",
         [(t, t, session[t], f"{count(session[t])} tokens") for t in tools]),
        ("Memory while idle", "after the turn ends", [(t, t, memory[t], f"{count(memory[t])} MB") for t in tools]),
    ]


def text(x, y, content, fill, size=13, weight=400, anchor="start"):
    return (f'<text x="{x}" y="{y}" fill="{fill}" font-size="{size}" font-weight="{weight}" '
            f'text-anchor="{anchor}">{escape(content)}</text>')


def bar(x, y, width, fill):
    """A bar anchored square to its baseline, with a 4px round on its data end."""
    r = min(4, width / 2)
    return (f'<path d="M{x} {y}h{width - r:.1f}a{r} {r} 0 0 1 {r} {r}v{BAR_HEIGHT - 2 * r}a{r} {r} 0 0 1 -{r} {r}'
            f'h-{width - r:.1f}z" fill="{fill}"/>')


def draw(title, subtitle, rows, footer, theme):
    colors = THEMES[theme]
    y, body = 124, []
    for label, note, bars in rows:
        top = max(value for _, _, value, _ in bars)
        block = len(bars) * BAR_HEIGHT + (len(bars) - 1) * BAR_GAP
        body.append(text(28, y + block / 2 - 2, label, colors["ink"], 15, 600))
        body.append(text(28, y + block / 2 + 15, note, colors["muted"], 12))
        for index, (tool, name, value, shown) in enumerate(bars):
            bar_y = y + index * (BAR_HEIGHT + BAR_GAP)
            width = max(MIN_BAR, value / top * BAR_MAX)
            body.append(bar(LEFT, bar_y, width, colors[tool]))
            caption = shown if name == tool else f"{shown} ({name.split(', ')[1]})"
            body.append(text(LEFT + width + 8, bar_y + 11.5, caption, colors["soft"], 12))
        y += block + ROW_GAP
    legend, x = [], 28
    for tool, width in (("ucu", 62), ("Codex engine", 124), ("agent-desktop", 130)):
        legend.append(f'<rect x="{x}" y="77" width="12" height="12" rx="3" fill="{colors[tool]}"/>')
        legend.append(text(x + 18, 88, "UCU" if tool == "ucu" else tool, colors["soft"], 13))
        x += width
    height = y + 34
    return f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {WIDTH} {height}" width="{WIDTH}" height="{height}" font-family="{FONT}" role="img" aria-label="{escape(title)}">
<title>{escape(title)}</title>
<rect x="0.5" y="0.5" width="{WIDTH - 1}" height="{height - 1}" rx="14" fill="{colors['surface']}" stroke="{colors['border']}"/>
{text(28, 42, title, colors['ink'], 24, 700)}
{text(28, 63, subtitle, colors['muted'], 13)}
{''.join(legend)}
{''.join(body)}
{text(28, height - 16, footer, colors['muted'], 11)}
</svg>
"""


def charts(results):
    """One image per idea, with at most three rows, so a reader can follow each one."""
    speed, tokens = rows_speed(results), rows_tokens(results)
    faster = "Shorter is faster. UCU runs the Codex engine, so those two differ only by noise."
    better = "Shorter is better. Tokens are estimated as characters / 4."
    return {
        "speed-actions": ("Speed: single actions", faster, speed[:3]),
        "speed-jobs": ("Speed: longer jobs", faster, speed[3:]),
        "tokens": ("Tokens per job", better, tokens[:3]),
        "overhead": ("Setup and idle memory", better, tokens[3:]),
    }


def main():
    results = json.loads((ROOT / "benchmarks/results.json").read_text())
    versions = results["versions"]
    footer = (f"Medians on an {versions['chip']}, macOS {versions['macOS']}. agent-desktop {versions['agent-desktop']}, "
              f"Codex plugin {versions['codex plugin']}. Each row has its own scale. Reproduce: benchmarks/run.py")
    folder = ROOT / "assets/benchmarks"
    folder.mkdir(parents=True, exist_ok=True)
    for name, (title, subtitle, rows) in charts(results).items():
        for theme in THEMES:
            (folder / f"{name}-{theme}.svg").write_text(draw(title, subtitle, rows, footer, theme))


if __name__ == "__main__":
    main()
