#!/usr/bin/env python3
import subprocess, os, re
from datetime import datetime
from typing import Optional, Tuple
import json

# Determine hidden vs visible feedback
def is_visible_test(test_name: str, visible_indices: list) -> bool:
    # test_name like 'tests/testin_6.txt'
    match = re.search(r'testin_(\d+)\.txt', test_name)
    if match:
        idx = int(match.group(1))
        return idx in visible_indices
    return True


def hidden_feedback_for(test_name: str, visible_indices: list, hidden_messages: dict) -> str:
    match = re.search(r'testin_(\d+)\.txt', test_name)
    if match:
        idx = match.group(1)
        message = hidden_messages.get(idx, None)
        if message:
            return message
    return "Hidden test feedback unavailable."

# Deduction helper to add string describing deduction along with actual deduction
def deduct(entries, per_case, label, points, msg, visible_indices, hidden_messages):
    for inp, t in dict.fromkeys(entries):
        deduction = per_case
        points -= deduction
        if is_visible_test(inp, visible_indices):
            msg.append(f"-{deduction:.4f} {label} on {inp} with {t} threads")
        else:
            hint = hidden_feedback_for(inp, visible_indices, hidden_messages)
            msg.append(f"-{deduction:.4f} {label} on hidden test {inp} with {t} threads ({hint})")

    return points


def run_autograder() -> Tuple[Optional[float], str, str]:
    """Runs the autograder and computes a (score, message)."""
    result_dir = "result"
    log_file = os.path.join(result_dir, "result.txt")

    # Keep old results and the current run's outputs for inspection.
    if os.path.exists(result_dir):
        os.rename(result_dir, result_dir + "_" + datetime.now().strftime("%Y%m%d_%H%M%S_%f"))

    # Load configuration
    try:
        with open("config.json") as f:
            config = json.load(f)
        if not isinstance(config, dict):
            raise ValueError("config.json must contain an object")
        for key in ("visible_indices", "speedup_indices"):
            indices = config.get(key, [])
            if (not isinstance(indices, list) or
                    any(type(i) is not int or i < 0 for i in indices) or
                    len(indices) != len(set(indices))):
                raise ValueError(f"{key} must contain distinct nonnegative integers")
        if not config.get("speedup_indices"):
            raise ValueError("speedup_indices must not be empty for a /12 grade")
        if not isinstance(config.get("hidden_messages", {}), dict):
            raise ValueError("hidden_messages must be an object")
        if any(not isinstance(v, str) for v in config.get("hidden_messages", {}).values()):
            raise ValueError("hidden_messages must contain text hints")
    except (OSError, ValueError) as error:
        return None, "Grading setup failed; no student score issued.", str(error)

    visible_indices = config.get("visible_indices", [])
    hidden_messages = config.get("hidden_messages", {})
    speedup_indices = config.get("speedup_indices", [])

    # Run the bash autograder
    try:
        run = subprocess.run(["bash", "autograder.sh"], capture_output=True, text=True)
    except OSError as error:
        return None, "Grading setup failed; no student score issued.", str(error)
    if os.path.isdir(result_dir):
        with open(os.path.join(result_dir, "autograder_stderr.txt"), "w") as f:
            f.write(run.stderr)

    # A missing log means the grading setup did not complete.
    if not os.path.exists(log_file):
        return None, "Grading setup failed; no student score issued.", run.stderr or "Log file not created"

    with open(log_file) as f:
        logs = f.read()

    # Full run check: infrastructure errors are different from student errors.
    if "Setup Error:" in logs:
        return None, "Grading setup failed; no student score issued. See result/.", logs + run.stderr
    if "Exit Error" in logs:
        print("Non-runtime errors. Likely compilation failure.")
        return (0, "Program does not complete for some reason.\n See autograder.sh & attached Autograder Logs for more details.", logs)
    if run.returncode != 0:
        return None, "Autograder failed; no student score issued. See result/.", logs + run.stderr

    # Scoring
    points = 12.0
    msg = []

    threads = [1, 2, 4, 8, 16, 32, 64]
    num_threads = len(threads)
    num_tests = len(re.findall(r"=== Testing tests/testin_", logs))
    expected_cases = {(f"tests/{name}", str(t)) for name in os.listdir("tests")
                      if re.fullmatch(r"testin_(0|[1-9][0-9]*)\.txt", name)
                      and os.path.isfile(os.path.join("tests", name)) for t in threads}
    completed = re.findall(r"Completed case on (.*?) with (\d+) threads", logs)
    if (not num_tests or "Autograder completed successfully" not in logs or
            set(completed) != expected_cases or len(completed) != len(expected_cases) or
            num_tests * num_threads != len(expected_cases)):
        return None, "Autograder run was incomplete; no student score issued.", logs

    # Extract cases
    rt_errs = re.findall(r"Runtime error on (.*?) with (\d+) threads", logs)
    leaks = re.findall(r"Memory (?:leak|error) on (.*?) with (\d+) threads", logs)
    unit_fails = re.findall(r"Unit test fails on (.*?) with (\d+) threads", logs)
    speed_fails = re.findall(r"Speedup failure on (.*?) with (\d+) threads", logs)

    points = deduct(rt_errs, 0.25 / (num_tests * num_threads), "Runtime error", points, msg, visible_indices, hidden_messages)
    points = deduct(leaks, 0.25, "Memory error", points, msg, visible_indices, hidden_messages)
    points = deduct(unit_fails, 3 / (num_tests * num_threads), "Unit test fails", points, msg, visible_indices, hidden_messages)
    points = deduct(speed_fails, 8 / ((num_threads-1) * len(speedup_indices)), "Speedup fails", points, msg, visible_indices, hidden_messages)

    # Raw results and the compiled binary stay available after grading.

    points = max(points, 0)
    if points == 12.0:
        msg.append("All tests passed. Full credit given from Autograder.")
    return points, "\n".join(msg), logs


if __name__ == "__main__":
    points, msg, logs = run_autograder()
    if points is None:
        print("No score: grading setup failed.\n\n")
    else:
        print(f"Final Score: {points:.2f}/12.00\n\n")
    print("Written analysis (Questions 1-3): 18 points graded manually; assignment total 30.\n")
    
    print(f"**** Autograder Rubric Feedback (output of 'grade_wrapper.py') ****\n{msg}\n\n\n\n")

    print(f"**** Autograder Logs (output of 'autograder.sh') ****\n\n{logs}")
    raise SystemExit(2 if points is None else 0)
    
