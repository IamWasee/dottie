---
name: csv-data-analysis
description: Use when the user gives a CSV, TSV or Excel file and wants it understood: "analyze this spreadsheet", "what's in this data", "summarize sales.csv", "find anything weird", "clean this up".
---

# CSV Data Analysis

## When to use

- A table of data (CSV, TSV, XLSX, XLS, JSON lines) that needs summarizing, cleaning or exploring.
- Questions like "which month sold most", "is there a trend", "are there duplicates or bad rows".
- Not for making a polished chart or dashboard as the main deliverable: use `charts-and-dashboards` (this skill makes quick charts only).
- Not for collecting the data from websites: use `web-scraping-politely` first.
- Not for building or formatting a spreadsheet file as the deliverable: use `spreadsheets`.

## Steps

1. Copy the file into `tmp/` and work on the copy. Never modify the user's original.
2. Peek before loading: `head -5 tmp/data.csv` and `wc -l tmp/data.csv` to see the delimiter, header row, encoding problems and size.
3. Load with pandas. For CSV try `pd.read_csv(path)`; on errors try `sep=None, engine="python"` (sniffs the delimiter), `encoding="latin-1"`, or `skiprows` for title rows. For Excel, list sheets with `pd.ExcelFile(path).sheet_names` and load the one the user meant (ask only if it is truly ambiguous).
4. Profile: shape, `df.dtypes`, `df.isna().sum()`, `df.nunique()`, `df.describe(include="all")`, duplicated rows. Save to `tmp/profile.txt`.
5. Fix types: parse dates with `pd.to_datetime(errors="coerce")`, strip currency symbols and thousands separators before `pd.to_numeric`, trim whitespace in text, normalize obvious category spellings. Count what each fix changed.
6. Explore:
   - Distributions of numeric columns (median and quartiles, not only mean).
   - Top categories by count and by value.
   - Trends over time when there is a date column (`df.resample("M", on="date")`).
   - Correlations between numeric columns (`df.corr(numeric_only=True)`); report only strong ones (absolute value above 0.5) and say correlation is not cause.
   - Anomalies: values beyond 1.5 IQR, negative amounts where impossible, future dates, duplicates, sudden gaps.
7. Make 2 to 5 charts that answer the user's question, saved as PNG in `output/charts/` (150 dpi, labeled axes, title that states the finding).
8. Write `output/findings.md`: the question, 3 to 7 key findings with numbers, a data-quality section (rows dropped, fixes made, columns with missing values), and the chart images linked.
9. If you cleaned the data, save it as `output/<name>-clean.csv` and list every change in findings.md.

## Tools on a Mac

- `python3 -m pip install --user pandas matplotlib openpyxl` (openpyxl for .xlsx, add `xlrd` for old .xls).
- `head`, `wc -l`, `cut -d, -f1-5`, `sort | uniq -c` for a first look without Python.
- `file -I tmp/data.csv` shows the encoding.
- `qlmanage -p file.xlsx` previews a spreadsheet; `open -a Numbers file.csv` only if the user asks.
- Charts without a display: `import matplotlib; matplotlib.use("Agg")` before pyplot.

```python
import pandas as pd
df = pd.read_csv("tmp/data.csv", sep=None, engine="python")
df.columns = df.columns.str.strip()
print(df.shape); print(df.dtypes); print(df.isna().sum())
print(df.describe(include="all").T.head(30))
```

## Quality checklist

- Row counts before and after cleaning are stated, with the reason for each dropped row.
- Every number in findings.md was computed by code you ran, not estimated.
- Units and currencies are named; totals and averages say over what period.
- Charts open, have titles and axis labels, and are referenced in findings.md.
- Findings answer the user's actual question first; side discoveries come after.
- The original file is untouched.

## Reply to the user

Two or three sentences with the headline numbers and the path, for example "Sales grew 18% from January to June, driven by the West region; 42 duplicate orders were removed. Findings and four charts are in output/findings.md."

## Pitfalls

- European CSVs use `;` as delimiter and `,` as decimal: `pd.read_csv(path, sep=";", decimal=",")`.
- Excel dates may arrive as serial numbers (like 45291); convert with `pd.to_datetime(col, unit="D", origin="1899-12-30")`.
- Leading zeros in IDs and ZIP codes vanish unless you load them as text: `dtype={"zip": str}`.
- Means hide skew. Report medians for money, time and counts.
- Large files (over about 1 GB): load selected columns with `usecols` or read in chunks.
- Do not fill missing values silently. Say how many and what you did.
- Do not send the data anywhere or upload it to online tools.

Based on: popular "csv-data-summarizer" skill
