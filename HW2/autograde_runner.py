import subprocess
import shutil
import os
import re

def run_autograder():
    """
    Runs the autograder.sh bash script, parses the logs,
    and returns (logs, final_score).
    """

    build_dir = "build"
    script_path = "./autograder.sh"
    base_score = 12.0
    final_score = base_score
    logs = ""

    # ---- Run the autograder ----
    try:
        result = subprocess.run(
            ["bash", script_path],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            check=False
        )
        logs = result.stdout
    except FileNotFoundError:
        logs = "autograder.sh not found.\n"
        return logs, 0
    except Exception as e:
        logs = f"Unexpected error running autograder.sh: {e}\n"
        return logs, 0

    # ---- Check compilation ----
    if "Compilation failed." in logs:
        final_score -= 12.0
        final_score = max(0, final_score)
        return logs, int(round(final_score))
    
    # Indicate that autograder failed to complete at some point
    if "All tests complete" not in logs:
        return None, None

    # ---- Initialize counters ----
    total_tests = 53
    total_speedups = 8
    timeout_or_runtime_fails = 0
    unit_test_fails = 0
    speedup_fails = 0

    # ---- Parse the logs ----
    for line in logs.splitlines():
        line = line.strip()

        if re.search(r"(TIMEOUT|RUNTIME ERROR)", line):
            timeout_or_runtime_fails += 1
        elif "UNIT TEST FAILED" in line:
            unit_test_fails += 1
        elif "SPEEDUP FAIL" in line:
            speedup_fails += 1

    # ---- Apply penalties ----
    final_score -= (timeout_or_runtime_fails * (9 / total_tests))
    final_score -= (unit_test_fails * (8 / total_tests))
    final_score -= (speedup_fails * (3 / total_speedups))
    final_score = max(0, final_score)

    # ---- Cleanup build directory ----
    if os.path.exists(build_dir):
        try:
            shutil.rmtree(build_dir)
        except Exception:
            # In case of permissions or partial cleanup, attempt per-file removal
            for root, dirs, files in os.walk(build_dir, topdown=False):
                for f in files:
                    try:
                        os.remove(os.path.join(root, f))
                    except Exception:
                        pass
                for d in dirs:
                    try:
                        os.rmdir(os.path.join(root, d))
                    except Exception:
                        pass
            try:
                os.rmdir(build_dir)
            except Exception:
                pass

    return logs, final_score


# ---- Optional standalone execution ----
if __name__ == "__main__":
    logs, score = run_autograder()
    print("========== AUTOGRADER LOGS ==========")
    print(logs)
    print("========== FINAL SCORE ==========")
    print(f"{score}/12")
