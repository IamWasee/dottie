---
name: charts-and-dashboards
description: Use when the user wants a chart, graph, plot or small dashboard made from data: "chart this", "make a graph of", "visualize these numbers", "build me a dashboard page".
---

# Charts and Dashboards

## When to use

- Turning numbers into a PNG/SVG chart or a single-file HTML dashboard the user can open in a browser.
- Restyling or fixing a chart that is hard to read.
- Not for exploring an unknown dataset: use `csv-data-analysis` first, then this skill for the final visuals.

## Steps

1. Get the data into a tidy table (one row per observation, one column per variable) in `tmp/data.csv`. Check totals against the source.
2. Decide the one message each chart should carry and write it as the title, for example "Signups doubled after the March launch".
3. Pick the chart by the question:
   - Change over time: line chart (bars if fewer than about 8 periods).
   - Compare categories: horizontal bar chart, sorted by value.
   - Part of a whole: stacked bar, or a pie only with 2 to 4 slices.
   - Relationship between two numbers: scatter plot, with a trend line if it helps.
   - Distribution: histogram or box plot.
   - A single headline number: a big-number tile, not a chart.
4. Choose the output:
   - Static image for documents and messages: matplotlib PNG at 200 dpi, or SVG for print.
   - Interactive page: one HTML file using Chart.js from a CDN, data embedded inline as JSON.
5. Label everything: title, axis titles with units, readable tick labels, source note under the chart. Start bar axes at zero. Use thousands separators.
6. Use a colorblind-safe palette. Okabe-Ito: `#E69F00 #56B4E9 #009E73 #F0E442 #0072B2 #D55E00 #CC79A7 #000000`. Use one strong color for the series that matters and gray for the rest. No more than 6 colors in one chart.
7. For a dashboard: a row of 2 to 4 number tiles at top, then 2 to 4 charts in a responsive grid, a date of the data, and a source line. Keep it to one screen when possible.
8. Save to `output/` (`output/signups-by-month.png`, `output/dashboard.html`) and render a check: `qlmanage -t -s 1200 -o tmp output/signups-by-month.png` or open the HTML headless (see Tools).

## Tools on a Mac

- `python3 -m pip install --user matplotlib pandas`.

```python
import matplotlib; matplotlib.use("Agg")
import matplotlib.pyplot as plt
fig, axis = plt.subplots(figsize=(8, 4.5), dpi=200)
axis.bar(months, signups, color="#0072B2")
axis.set_title("Signups doubled after the March launch", loc="left")
axis.set_ylabel("Signups per month")
axis.spines[["top", "right"]].set_visible(False)
fig.text(0.01, 0.01, "Source: app analytics, Jan-Jun 2026", fontsize=8, color="gray")
fig.tight_layout(); fig.savefig("output/signups-by-month.png")
```

- Chart.js in one HTML file: `<script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.1/dist/chart.umd.min.js"></script>`, a `<canvas id="signups">`, and `new Chart(document.getElementById("signups"), {type: "bar", data: {...}, options: {...}})`. Pin the version.
- Respect dark mode in HTML with `@media (prefers-color-scheme: dark)` and set Chart.js `color` and grid colors from CSS variables.
- Screenshot an HTML page to check it: `python3 -m pip install --user playwright && python3 -m playwright install chromium`, then `page.screenshot(path="tmp/dash.png", full_page=True)`.
- `sips -Z 1600 output/chart.png` to shrink an image; `open output/dashboard.html` only if the user asks to see it.

## Quality checklist

- The title states the finding, not just the variables.
- Axes are labeled with units; bar charts start at zero; dates are in order.
- Colors pass for colorblind viewers and the important series stands out.
- Values in the chart match the source table (spot-check three).
- Text is readable at the size it will be seen (no tick labels under 8 pt).
- The HTML file works offline except for the pinned CDN script, and the page has a `<title>`.

## Reply to the user

One or two sentences: what the chart shows and where it is, for example "The bar chart shows signups doubling after the March launch; it's in output/signups-by-month.png."

## Pitfalls

- Dual y-axes mislead; use two charts side by side.
- 3D charts, heavy gridlines and gradients make values harder to read.
- Pie charts with many slices; use sorted bars.
- Truncated y-axis on bars exaggerates differences.
- Red and green as the only distinction fails for the most common color blindness.
- Loading an unpinned CDN URL (`chart.js@latest`) can break the page later.
- Do not publish or upload the dashboard; saving it in `output/` is the job.

Based on: written for Dottie
