"""Decision lab: times small Jev-style decision models on Dottie's screen steps.

Each case is one step of a screen job: the goal, what's been done, and the
elements the Mac would find on screen (labels from text reading and
Accessibility, no screenshot). The model picks the next step as a "choice"
question. We record whether it picked an acceptable answer, its confidence,
how long each answer took, and the most memory the model used.

Usage: python run.py <model> <cases.json>
Models: laya, laya-typed, bosun, kev and kev4b (Kev's server on :8009),
tev1 and kev4b-q4 (Ollama on :11434), clef-flash (llama-server on :8097)
"""

import json
import os
import resource
import statistics
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request

INSTRUCTIONS = (
    "What should Dottie do next to reach the goal? Pick finish only when the goal is already done on screen. "
    "Pick ask_user before paying or placing an order, when a password or code is needed that nobody saved, "
    "or for a captcha."
)

GENERIC_STEPS = {
    "open_app": "open the app named in the goal (it isn't open or visible yet)",
    "wait": "wait, the screen is still loading",
    "scroll": "scroll down, what's needed isn't visible yet",
    "finish": "the goal is already done on screen, so finish",
    "ask_user": "ask the user first: paying, a password or code nobody saved, or a captcha",
}


def state_text(case):
    done_text = "; ".join(case["done"]) if case["done"] else "nothing yet"
    element_lines = [
        f"- {element_id}: {kind} \"{label}\" ({where})"
        for element_id, kind, label, where in case["screen"]
    ]
    return (
        f"Goal: {case['goal']}\n"
        f"Front app: {case['app']}\n"
        f"Done so far: {done_text}\n"
        "On screen:\n" + "\n".join(element_lines)
    )


def step_options(case):
    """Candidate next steps: a click per element, typing for fields, then the generic steps."""
    options = {}
    for element_id, kind, label, _where in case["screen"]:
        options[f"click_{element_id}"] = f"click the {kind} \"{label}\""
        if kind == "field":
            options[f"type_{element_id}"] = f"type into the field \"{label}\" and press return"
    options.update(GENERIC_STEPS)
    return options


# MARK: - Models


class LayaModel:
    def __init__(self, subfolder):
        import laya

        self.agent = laya.load("convaiinnovations/laya", subfolder=subfolder) if subfolder else laya.load("convaiinnovations/laya")

    def decide(self, state, options):
        result = self.agent.predict(state, {"next_step": {"type": "choice", "instructions": INSTRUCTIONS, "criteria": options}})
        answer = result["answers"]["next_step"]
        return answer["choice"], answer.get("confidence"), answer.get("probabilities", {})


class BosunModel:
    def __init__(self):
        import torch
        from transformers import AutoModelForCausalLM

        print("torch", torch.__version__, "mps available:", torch.backends.mps.is_available(), flush=True)
        self.model = AutoModelForCausalLM.from_pretrained(
            "Hanno-Labs/bosun-v3.1-0.6b", trust_remote_code=True, dtype="auto", device_map="auto"
        )
        self.row_number = 0

    def decide(self, state, options):
        self.row_number += 1
        option_ids = list(options.keys())
        result = self.model.predict(
            state={"screen": state},
            instructions=INSTRUCTIONS,
            decision_type="choice",
            row_id=f"row-{self.row_number}",
            candidates=[{"id": option_id, "label": option_id, "description": options[option_id]} for option_id in option_ids],
        )
        probabilities = result["probabilities"]
        if isinstance(probabilities, list):
            probabilities = dict(zip(option_ids, [float(value) for value in probabilities]))
        chosen_option = max(probabilities, key=probabilities.get)
        return chosen_option, probabilities[chosen_option], probabilities


class SystemOneServerModel:
    """Kev's server and Ollama both answer the Jev-style /v1/systemone route."""

    def __init__(self, base_url, model_name, server_process_name):
        self.base_url = base_url
        self.model_name = model_name
        self.server_process_name = server_process_name
        self.sends_state_as_object = False

    def post(self, state, options):
        body = {
            "model": self.model_name,
            "state": {"screen": state} if self.sends_state_as_object else state,
            "questions": {"next_step": {"type": "choice", "instructions": INSTRUCTIONS, "criteria": options}},
        }
        request = urllib.request.Request(
            self.base_url + "/v1/systemone",
            data=json.dumps(body).encode(),
            headers={"content-type": "application/json"},
        )
        with urllib.request.urlopen(request, timeout=300) as response:
            return json.loads(response.read())

    def decide(self, state, options):
        try:
            result = self.post(state, options)
        except urllib.error.HTTPError as error:
            if self.sends_state_as_object:
                raise
            print("server refused a text state, retrying as an object:", error.code, error.read()[:300], flush=True)
            self.sends_state_as_object = True
            result = self.post(state, options)
        answer = result["answers"]["next_step"]
        return answer["choice"], answer.get("confidence"), answer.get("probabilities", {})


# MARK: - Memory


class ServerMemorySampler:
    """Peak resident memory of a server process (and its children), sampled while the cases run."""

    def __init__(self, process_name):
        self.process_name = process_name
        self.peak_bytes = 0
        self.keeps_sampling = True
        self.thread = threading.Thread(target=self.sample, daemon=True)
        self.thread.start()

    def sample(self):
        while self.keeps_sampling:
            output = subprocess.run(["ps", "-axo", "rss=,command="], capture_output=True, text=True).stdout
            total_kilobytes = 0
            for line in output.splitlines():
                parts = line.strip().split(None, 1)
                if len(parts) == 2 and self.process_name in parts[1] and "run.py" not in parts[1]:
                    total_kilobytes += int(parts[0])
            self.peak_bytes = max(self.peak_bytes, total_kilobytes * 1024)
            time.sleep(0.2)

    def stop(self):
        self.keeps_sampling = False
        self.thread.join()


def own_peak_memory_bytes():
    # ru_maxrss is in bytes on macOS.
    return resource.getrusage(resource.RUSAGE_SELF).ru_maxrss


# MARK: - Running


def make_model(model_key):
    if model_key == "laya":
        return LayaModel(None), None
    if model_key == "laya-typed":
        return LayaModel("typed-decisions"), None
    if model_key == "bosun":
        return BosunModel(), None
    if model_key in ("kev", "kev4b"):
        return SystemOneServerModel("http://127.0.0.1:8009", "kev-latest", "kev.serve"), "kev.serve"
    if model_key == "tev1":
        return SystemOneServerModel("http://127.0.0.1:11434", "tev1:0.8b", "ollama"), "ollama"
    if model_key == "kev4b-q4":
        return SystemOneServerModel("http://127.0.0.1:11434", "turintech/kev-4b-artemis:2.0gb", "ollama"), "ollama"
    if model_key == "clef-flash":
        return SystemOneServerModel("http://127.0.0.1:8097", "clef-flash", "llama-server"), "llama-server"
    raise SystemExit(f"unknown model {model_key}")


def percentile(values, fraction):
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(round(fraction * (len(ordered) - 1))))]


def main():
    model_key, cases_path = sys.argv[1], sys.argv[2]
    with open(cases_path) as cases_file:
        cases = json.load(cases_file)

    load_started_at = time.perf_counter()
    model, server_process_name = make_model(model_key)
    load_seconds = time.perf_counter() - load_started_at
    memory_sampler = ServerMemorySampler(server_process_name) if server_process_name else None

    # The first answer includes warming up (compiling, caches), so it's timed on its own.
    first_case = cases[0]
    first_started_at = time.perf_counter()
    model.decide(state_text(first_case), step_options(first_case))
    first_answer_milliseconds = (time.perf_counter() - first_started_at) * 1000

    rows = []
    for case in cases:
        options = step_options(case)
        started_at = time.perf_counter()
        try:
            chosen_option, confidence, _probabilities = model.decide(state_text(case), options)
            error_text = None
        except Exception as error:  # a model failing one case shouldn't hide the others
            chosen_option, confidence, error_text = None, None, repr(error)[:300]
        milliseconds = (time.perf_counter() - started_at) * 1000
        is_right = chosen_option in case["answer"]
        rows.append({
            "id": case["id"], "chosen": chosen_option, "expected": case["answer"], "right": is_right,
            "confidence": confidence, "ms": round(milliseconds, 1), "options": len(options), "error": error_text,
        })
        mark = "OK " if is_right else "XX "
        confidence_text = f"{confidence:.2f}" if isinstance(confidence, (int, float)) else "-"
        print(f"{mark}{case['id']:<22} chose {chosen_option!s:<12} want {'/'.join(case['answer']):<20} conf {confidence_text:<5} {milliseconds:7.1f} ms"
              + (f"  ERROR {error_text}" if error_text else ""), flush=True)

    if memory_sampler:
        memory_sampler.stop()
    peak_memory_bytes = memory_sampler.peak_bytes if memory_sampler else own_peak_memory_bytes()

    answered_rows = [row for row in rows if row["error"] is None]
    latencies = [row["ms"] for row in answered_rows] or [0]
    confident_buckets = {}
    for threshold in (0.5, 0.7, 0.9):
        confident_rows = [row for row in answered_rows if isinstance(row["confidence"], (int, float)) and row["confidence"] >= threshold]
        confident_buckets[str(threshold)] = {
            "share_of_cases": round(len(confident_rows) / len(rows), 3),
            "accuracy": round(sum(row["right"] for row in confident_rows) / len(confident_rows), 3) if confident_rows else None,
        }
    summary = {
        "model": model_key,
        "cases": len(rows),
        "errors": len(rows) - len(answered_rows),
        "accuracy": round(sum(row["right"] for row in rows) / len(rows), 3),
        "load_seconds": round(load_seconds, 1),
        "first_answer_ms": round(first_answer_milliseconds, 1),
        "median_ms": round(statistics.median(latencies), 1),
        "p90_ms": round(percentile(latencies, 0.9), 1),
        "peak_memory_mb": round(peak_memory_bytes / 1024 / 1024),
        "when_confident": confident_buckets,
        "wrong": [f"{row['id']}: chose {row['chosen']}" for row in rows if not row["right"]],
    }
    print("RESULT_JSON " + json.dumps(summary), flush=True)
    output_path = os.environ.get("DECISION_LAB_OUTPUT")
    if output_path:
        with open(output_path, "w") as output_file:
            json.dump({"summary": summary, "rows": rows}, output_file, indent=2)


if __name__ == "__main__":
    main()
