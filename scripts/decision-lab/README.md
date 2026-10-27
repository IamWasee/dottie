# Decision lab

Tests whether a small (under 1B) Jev-style decision model could pick the next step of a Dottie screen job fast enough, and well enough, to replace a Gemini round for simple jobs.

- `cases.json` has 40 steps from everyday jobs, including the Roblox search. Each step lists the goal, what's been done, and the on-screen elements the Mac would find without a screenshot. It also lists which next steps are acceptable.
- `run.py <model> cases.json` asks the model each step as a `choice` question. It prints one line per case and a `RESULT_JSON` summary: accuracy, accuracy when confident, first-answer and median milliseconds, and peak memory.
- Run it from Actions → Decision lab. Each model gets its own macOS runner job.

GitHub's Mac runners are virtual M1 machines with no GPU access, so the speeds are CPU speeds. A real Apple Silicon Mac should be faster.
