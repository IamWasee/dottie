#!/usr/bin/env bash
# Compares a measured number with its ceiling in scripts/ci/budgets.env and
# fails when it is over.
#
#   scripts/ci/check-budget.sh SWIFT_COMPILER_WARNING_BUDGET 212 "compiler warnings"
set -euo pipefail

budget_name="$1"
measured_count="$2"
what_was_counted="$3"

script_directory="$(cd "$(dirname "$0")" && pwd)"
budget_value="$(grep -E "^${budget_name}=" "$script_directory/budgets.env" | head -1 | cut -d= -f2)"

if [ -z "$budget_value" ]; then
  echo "::error::$budget_name is missing from scripts/ci/budgets.env."
  exit 1
fi

summary_file="${GITHUB_STEP_SUMMARY:-/dev/null}"

if [ "$budget_value" = "unset" ]; then
  echo "$measured_count $what_was_counted (no ceiling set yet)."
  echo "**$measured_count** $what_was_counted (no ceiling set yet)" >> "$summary_file"
  exit 0
fi

echo "$measured_count $what_was_counted, ceiling $budget_value."
echo "**$measured_count** $what_was_counted (ceiling $budget_value)" >> "$summary_file"

if [ "$measured_count" -gt "$budget_value" ]; then
  echo "::error::$measured_count $what_was_counted, over the ceiling of $budget_value in scripts/ci/budgets.env. Fix the new ones instead of raising the ceiling."
  exit 1
fi

if [ "$measured_count" -lt "$budget_value" ]; then
  echo "::notice::Only $measured_count $what_was_counted now. Lower $budget_name in scripts/ci/budgets.env to $measured_count to keep the gain."
fi
