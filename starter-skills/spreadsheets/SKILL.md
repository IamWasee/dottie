---
name: spreadsheets
description: Use when the task is a spreadsheet: make, clean, analyze or fix an .xlsx, .csv or Numbers file, add formulas, totals, charts or formatting, or convert between spreadsheet formats.
---

# Spreadsheets

## When to use

- Creating a workbook from data, a budget, a tracker or a model.
- Cleaning a messy CSV or .xlsx (headers, dates, duplicates, types).
- Adding formulas, summaries, pivots, conditional formatting or charts.
- Converting .xlsx, .csv and Numbers files.
- Not when the user only wants a number answered: compute it and reply, no file needed.

## Steps

1. Copy inputs to `tmp/` and look before changing anything: sheet names, header row, row count, column types.
   `python3 -c "import pandas as pd; x=pd.read_excel('tmp/in.xlsx', sheet_name=None); [print(k, v.shape, list(v.columns)) for k,v in x.items()]"`
2. Plan the layout: one table per sheet, headers in row 1, one row per record, no merged cells inside data, inputs and assumptions on their own sheet or clearly marked block.
3. Use pandas for cleaning and analysis, openpyxl for the final workbook with formulas and formatting.
4. Write formulas, not computed values, for anything the user might change: totals, ratios, growth, lookups. A cell that holds `=SUM(B2:B13)` stays right when inputs change; a pasted number does not.
5. Format: bold header, freeze the top row, sensible column widths, number formats (currency, percent, dates), an autofilter on tables.
6. Add a chart only if it helps answer the question.
7. Save to `output/<name>.xlsx` (and `.csv` if asked). Recalculate and check for errors (below).

## Tools on a Mac

- `python3 -m pip install --user openpyxl pandas`

```python
from openpyxl import Workbook
from openpyxl.styles import Font
from openpyxl.chart import BarChart, Reference
workbook = Workbook()
sheet = workbook.active
sheet.title = "Budget"
sheet.append(["Month", "Income", "Spend", "Saved"])
for row_number, (month, income, spend) in enumerate(data, start=2):
    sheet.append([month, income, spend, f"=B{row_number}-C{row_number}"])
last_row = sheet.max_row
sheet.append(["Total", f"=SUM(B2:B{last_row})", f"=SUM(C2:C{last_row})", f"=SUM(D2:D{last_row})"])
for cell in sheet[1]:
    cell.font = Font(bold=True)
sheet.freeze_panes = "A2"
for column in "BCD":
    for cell in sheet[column][1:]:
        cell.number_format = '"$"#,##0.00'
chart = BarChart()
chart.add_data(Reference(sheet, min_col=4, min_row=1, max_row=last_row), titles_from_data=True)
chart.set_categories(Reference(sheet, min_col=1, min_row=2, max_row=last_row))
sheet.add_chart(chart, "F2")
workbook.save("output/budget.xlsx")
```

- Read values a formula produced: `openpyxl.load_workbook(path, data_only=True)` (only works after Excel or Numbers has saved the file).
- Recalculate and check formulas without Excel: `brew install --cask libreoffice`, then `soffice --headless --convert-to xlsx --outdir tmp output/budget.xlsx` and load `tmp/budget.xlsx` with `data_only=True`; scan every cell for `#REF!`, `#DIV/0!`, `#VALUE!`, `#NAME?`. Ask before installing LibreOffice.
- Numbers to Excel or CSV (Numbers installed):

```bash
osascript -e 'tell application "Numbers"
  set theDoc to open POSIX file "/full/path/in.numbers"
  export theDoc to POSIX file "/full/path/tmp/in.xlsx" as Microsoft Excel
  close theDoc saving no
end tell'
```

- CSV quick look: `head -5 file.csv`, `wc -l file.csv`, `file file.csv` (encoding).
- `qlmanage -t -s 1200 -o tmp output/budget.xlsx` for a preview image.

## Quality checklist

- Totals and derived columns are formulas; spot-check two by hand.
- No formula errors anywhere after recalculation.
- Headers in row 1, frozen, bold; no blank rows inside tables.
- Dates are real dates, numbers are numbers (not text with spaces or currency symbols).
- Row count after cleaning matches what you expect; note any rows dropped and why.
- Original file untouched.

## Reply to the user

One to three sentences: what the sheet holds, the headline number if there is one, the path. For example: "Built a 12-month budget with live totals and a savings chart; you'd save $4,210 at this pace. It's at output/budget.xlsx."

## Pitfalls

- pandas `to_excel` writes values only and loses formatting; build the final file with openpyxl or style it after.
- Saving with openpyxl drops existing charts, images and pivot tables in a workbook you loaded. For those files, write a new sheet or a new workbook instead of rewriting the old one.
- `data_only=True` then `save()` replaces every formula with its cached value. Never save a workbook you opened that way.
- CSV from Excel on a Mac may be UTF-16 or use semicolons; pass `encoding` and `sep` to `read_csv`.
- Leading zeros (zip codes, IDs) vanish unless the column is read as `dtype=str`.
- Hardcoding a total because the formula was fiddly defeats the purpose of the sheet.

Based on: anthropics/skills "xlsx"
