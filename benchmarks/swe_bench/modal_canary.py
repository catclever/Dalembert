#!/usr/bin/env python3
"""
Dalembert x EnginEdge SWE-bench 1-Task Modal Canary Runner (Zero-Extra-Bill Guarded).

Usage (PVE only):
  /root/Projects/ruby_lab/Dalembert/benchmarks/swe_bench/.venv/bin/python \
    /root/Projects/ruby_lab/Dalembert/benchmarks/swe_bench/modal_canary.py \
    --instance-id django__django-11099 --limit 1 --profile default --model hy4
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import re
import subprocess
import sys
import threading
import time
import urllib.request
from pathlib import Path

import modal
import pyarrow.compute as pc
import pyarrow.parquet as pq

DEFAULT_WS_URL = "wss://dalembert-production.up.railway.app"
DEFAULT_ENGINEDGE_BIN = "/root/Projects/EnginEdge/target/release/enginedge"
DEFAULT_MODAL_BIN = "/root/.local/bin/modal"
DEFAULT_PARQUET_PATH = "/tmp/swebench_verified.parquet"
PARQUET_URL = (
    "https://huggingface.co/datasets/princeton-nlp/SWE-bench_Verified/"
    "resolve/refs%2Fconvert%2Fparquet/default/test/0000.parquet"
)
CLOUD_OSINT_TOOLS = (
    "github_repo_survey",
    "survey_architecture",
    "github_code_search",
    "search_code_examples",
    "doc_fetcher",
    "fetch_doc",
    "spec_inspector",
    "inspect_spec",
    "knowledge_store",
)


def run_billing_summary(modal_bin: str) -> str:
    proc = subprocess.run([modal_bin, "billing", "summary"], text=True, capture_output=True)
    output = (proc.stdout + proc.stderr).strip()
    if proc.returncode != 0:
        raise RuntimeError(f"modal billing summary failed (rc={proc.returncode}):\n{output}")
    return output


def assert_zero_billed_cost(summary_text: str, phase: str) -> None:
    if "Billed Cost:    $0.00" not in summary_text and not re.search(
        r"Billed Cost:\s*\$0\.00\b", summary_text
    ):
        raise RuntimeError(
            f"[{phase}] Guardrail violation: Billed Cost is not $0.00!\n{summary_text}"
        )


def load_swebench_instance(instance_id: str, parquet_path: Path) -> dict:
    if not parquet_path.is_file():
        print(f"[Dataset] Downloading SWE-bench_Verified parquet to {parquet_path}...")
        parquet_path.parent.mkdir(parents=True, exist_ok=True)
        urllib.request.urlretrieve(PARQUET_URL, str(parquet_path))

    table = pq.read_table(str(parquet_path))
    filtered = table.filter(pc.equal(table["instance_id"], instance_id))
    rows = filtered.to_pylist()
    if not rows:
        raise RuntimeError(f"Instance '{instance_id}' not found in {parquet_path}")
    row = rows[0]
    for key in ("FAIL_TO_PASS", "PASS_TO_PASS"):
        val = row.get(key)
        if isinstance(val, str):
            row[key] = json.loads(val)
    return row


def candidate_images_for(instance_id: str) -> list[str]:
    dockerhub_id = instance_id.replace("__", "_1776_")
    return [
        f"ghcr.io/epoch-research/swe-bench.eval.x86_64.{instance_id}:latest",
        f"swebench/sweb.eval.x86_64.{dockerhub_id}:latest",
    ]


def stream_process_output(proc) -> tuple[int, str, str]:
    stdout_chunks: list[str] = []
    stderr_chunks: list[str] = []

    def reader(pipe, chunks: list[str], prefix: str) -> None:
        for line in pipe:
            chunks.append(line)
            print(f"{prefix}{line}", end="", flush=True)

    t_out = threading.Thread(target=reader, args=(proc.stdout, stdout_chunks, "[OUT] "), daemon=True)
    t_err = threading.Thread(target=reader, args=(proc.stderr, stderr_chunks, "[ERR] "), daemon=True)
    t_out.start()
    t_err.start()
    proc.wait()
    t_out.join(timeout=5)
    t_err.join(timeout=5)
    return proc.returncode, "".join(stdout_chunks), "".join(stderr_chunks)


def audit_logs(stdout_text: str, stderr_text: str) -> dict:
    combined = f"{stdout_text}\n{stderr_text}"
    phases_seen: list[str] = []
    for m in re.finditer(
        r"(?:phase_change[^a-zA-Z0-9_]+(locate|reproduce|patch_and_verify)|Phase\s+\d/3\s+\[:(locate|reproduce|patch_and_verify)\])",
        combined,
    ):
        phase = m.group(1) or m.group(2)
        if not phases_seen or phases_seen[-1] != phase:
            phases_seen.append(phase)

    cloud_tool_hits: list[str] = []
    for line in combined.splitlines():
        low = line.lower()
        if any(marker in low for marker in ("tool_call", "executing tool", "tool:")):
            for tool_name in CLOUD_OSINT_TOOLS:
                if tool_name in low:
                    cloud_tool_hits.append(f"{tool_name}: {line.strip()[:160]}")

    return {
        "phases_seen": phases_seen,
        "cloud_osint_hits": cloud_tool_hits,
        "cloud_osint_count": len(cloud_tool_hits),
    }


def write_remote_b64_file(sb: modal.Sandbox, remote_path: str, content: str) -> None:
    b64 = base64.b64encode(content.encode("utf-8")).decode("ascii")
    py_cmd = (
        "import base64; "
        f"open({remote_path!r}, 'wb').write(base64.b64decode({b64!r}))"
    )
    proc = sb.exec("/opt/miniconda3/envs/testbed/bin/python", "-c", py_cmd)
    out = proc.stdout.read()
    err = proc.stderr.read()
    proc.wait()
    if proc.returncode != 0:
        raise RuntimeError(f"Failed writing {remote_path} (rc={proc.returncode}): {out}\n{err}")


def extract_django_test_modules(test_names: list[str]) -> list[str]:
    modules: list[str] = []
    for name in test_names:
        m = re.search(r"\(([^)]+)\)", name)
        if not m:
            continue
        cls_path = m.group(1)
        mod_path = cls_path.rsplit(".", 1)[0]
        if mod_path not in modules:
            modules.append(mod_path)
    return modules


def parse_django_test_results(output: str, expected_tests: list[str]) -> dict:
    passed: list[str] = []
    failed: list[str] = []
    missing: list[str] = []
    lines = output.splitlines()
    for test_id in expected_tests:
        # Django verbosity=2 format: "test_ascii_validator (auth_tests.test_validators.UsernameValidatorsTests) ... ok"
        matched_line = None
        for idx, line in enumerate(lines):
            if test_id in line:
                matched_line = line
                # Sometimes multi-line docstrings separate name and "... ok"
                if idx + 1 < len(lines) and not re.search(r"\.\.\.\s*(ok|FAIL|ERROR|skipped)", line):
                    matched_line = f"{line} {lines[idx + 1]}"
                break
        if matched_line is None:
            missing.append(test_id)
        elif re.search(r"\.\.\.\s*ok\s*$", matched_line):
            passed.append(test_id)
        else:
            failed.append(f"{test_id} -> {matched_line.strip()}")
    return {"passed": passed, "failed": failed, "missing": missing}


def create_solver_sandbox(
    app: modal.App,
    instance_id: str,
    enginedge_bin: str,
    ws_url: str,
    auth_token: str,
    sandbox_timeout: int,
) -> tuple[modal.Sandbox, str, modal.Image]:
    last_error = None
    for image_tag in candidate_images_for(instance_id):
        print(f"[Sandbox] Attempting base image: {image_tag}")
        try:
            base_image = modal.Image.from_registry(image_tag)
            solver_image = base_image.add_local_file(
                enginedge_bin, "/usr/local/bin/enginedge", copy=True
            ).run_commands("chmod +x /usr/local/bin/enginedge")
            sb = modal.Sandbox.create(
                app=app,
                image=solver_image,
                workdir="/testbed",
                timeout=sandbox_timeout,
                cpu=2.0,
                memory=4096,
                env={
                    "PATH": "/opt/miniconda3/envs/testbed/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
                },
                secrets=[
                    modal.Secret.from_dict(
                        {
                            "DALEMBERT_WS_URL": ws_url,
                            "HUB_AUTH_TOKEN": auth_token,
                        }
                    )
                ],
            )
            return sb, image_tag, base_image
        except Exception as exc:
            last_error = exc
            print(f"[Sandbox] Failed with image {image_tag}: {exc}")
    raise RuntimeError(f"All candidate images failed for {instance_id}: {last_error}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Dalembert x EnginEdge Modal SWE-bench 1-Task Canary")
    parser.add_argument("--instance-id", default="django__django-11099")
    parser.add_argument("--limit", type=int, default=1)
    parser.add_argument("--profile", default="default")
    parser.add_argument("--model", default="hy4")
    parser.add_argument("--max-turns", type=int, default=45)
    parser.add_argument("--agent-timeout", type=int, default=540)
    parser.add_argument("--sandbox-timeout", type=int, default=600)
    parser.add_argument("--ws-url", default=os.environ.get("DALEMBERT_WS_URL", DEFAULT_WS_URL))
    parser.add_argument("--enginedge-bin", default=DEFAULT_ENGINEDGE_BIN)
    parser.add_argument("--modal-bin", default=DEFAULT_MODAL_BIN)
    parser.add_argument("--parquet-path", default=DEFAULT_PARQUET_PATH)
    args = parser.parse_args()

    # Guardrail: strict 1-task serial canary only
    if args.limit != 1:
        print(f"ERROR: Canary guard requires --limit 1 (got {args.limit})", file=sys.stderr)
        return 1
    if not Path(args.enginedge_bin).is_file():
        print(f"ERROR: EnginEdge binary not found at {args.enginedge_bin}", file=sys.stderr)
        return 1

    run_dir = Path(__file__).resolve().parent / "runs" / args.instance_id
    run_dir.mkdir(parents=True, exist_ok=True)

    print("=== [1/6] Pre-Run Modal Billing Summary ===")
    pre_billing = run_billing_summary(args.modal_bin)
    print(pre_billing)
    assert_zero_billed_cost(pre_billing, "PRE-RUN")

    print(f"\n=== [2/6] Loading SWE-bench_Verified Instance: {args.instance_id} ===")
    instance = load_swebench_instance(args.instance_id, Path(args.parquet_path))
    problem_statement = instance["problem_statement"]
    test_patch = instance["test_patch"]
    base_commit = instance["base_commit"]
    fail_to_pass = list(instance["FAIL_TO_PASS"])
    pass_to_pass = list(instance["PASS_TO_PASS"])
    print(f"Loaded {args.instance_id} (base_commit={base_commit}, F2P={len(fail_to_pass)}, P2P={len(pass_to_pass)})")

    auth_token = os.environ.get("HUB_AUTH_TOKEN", "")
    app = modal.App.lookup("dalembert-swe-bench-canary", create_if_missing=True)

    model_patch = ""
    solver_rc = -1
    solver_stdout = ""
    solver_stderr = ""
    used_image_tag = ""
    base_image = None

    print("\n=== [3/6] Launching Solver Modal Sandbox (timeout=600s, cpu=2.0, memory=4096MB) ===")
    t0 = time.time()
    sb, used_image_tag, base_image = create_solver_sandbox(
        app=app,
        instance_id=args.instance_id,
        enginedge_bin=args.enginedge_bin,
        ws_url=args.ws_url,
        auth_token=auth_token,
        sandbox_timeout=args.sandbox_timeout,
    )
    try:
        # Check binary compatibility (GLIBC / libssl) first before running agent
        ver_proc = sb.exec("/usr/local/bin/enginedge", "--version")
        ver_out = ver_proc.stdout.read()
        ver_err = ver_proc.stderr.read()
        ver_proc.wait()
        print(f"[Binary Check] enginedge --version (rc={ver_proc.returncode}): {(ver_out + ver_err).strip()}")
        if ver_proc.returncode != 0:
            ldd_proc = sb.exec("sh", "-c", "ldd /usr/local/bin/enginedge || true; cat /etc/os-release || true")
            print("[Binary Mismatch Diagnostics]\n" + ldd_proc.stdout.read() + ldd_proc.stderr.read())
            ldd_proc.wait()
            return 2

        write_remote_b64_file(sb, "/tmp/problem_statement.txt", problem_statement)

        solve_script = (
            'export PATH="/opt/miniconda3/envs/testbed/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"\n'
            'PROBLEM_TEXT="$(cat /tmp/problem_statement.txt)"\n'
            'exec /usr/local/bin/enginedge --mode eval --hub-url "$DALEMBERT_WS_URL" run '
            f'--task-name "swe_{args.instance_id}" '
            '--workflow-mode swe_bench '
            '--no-cloud-tools '
            '--disabled-tools ping,echo '
            f'--profile "{args.profile}" '
            f'--model "{args.model}" '
            f'--max-turns {args.max_turns} '
            f'--timeout {args.agent_timeout} '
            '--task "$PROBLEM_TEXT"\n'
        )
        print(f"[Solver] Running enginedge (profile={args.profile}, model={args.model}, max_turns={args.max_turns}, timeout={args.agent_timeout}s)...")
        solve_proc = sb.exec("sh", "-c", solve_script, timeout=args.sandbox_timeout)
        solver_rc, solver_stdout, solver_stderr = stream_process_output(solve_proc)

        diff_proc = sb.exec("git", "-C", "/testbed", "diff")
        model_patch = diff_proc.stdout.read()
        diff_err = diff_proc.stderr.read()
        diff_proc.wait()
        if diff_err.strip():
            print(f"[git diff stderr] {diff_err.strip()}")

        status_proc = sb.exec("git", "-C", "/testbed", "status", "--short")
        print(f"[git status --short]\n{status_proc.stdout.read().strip()}")
        status_proc.wait()
    finally:
        print("[Sandbox] Terminating Solver Sandbox...")
        sb.terminate()

    solve_elapsed = time.time() - t0
    (run_dir / "enginedge_stdout.log").write_text(solver_stdout, encoding="utf-8")
    (run_dir / "enginedge_stderr.log").write_text(solver_stderr, encoding="utf-8")
    (run_dir / "model.patch").write_text(model_patch, encoding="utf-8")

    prediction_record = {
        "instance_id": args.instance_id,
        "model_name_or_path": f"dalembert-swe_bench-{args.model}",
        "model_patch": model_patch,
    }
    pred_path = run_dir / "predictions.jsonl"
    pred_path.write_text(json.dumps(prediction_record, ensure_ascii=False) + "\n", encoding="utf-8")

    audit = audit_logs(solver_stdout, solver_stderr)
    print(f"\n=== [4/6] Solver Audit (elapsed={solve_elapsed:.1f}s, rc={solver_rc}) ===")
    print(f"Image used: {used_image_tag}")
    print(f"Phases observed: {audit['phases_seen']}")
    print(f"Cloud OSINT tool hits: {audit['cloud_osint_count']}")
    print(f"Patch bytes: {len(model_patch)} -> {pred_path}")

    eval_summary = {
        "evaluated": False,
        "exit_code": None,
        "fail_to_pass": None,
        "pass_to_pass": None,
        "resolved": False,
    }

    if model_patch.strip():
        print("\n=== [5/6] Launching Clean Official Evaluation Sandbox (timeout=300s, cpu=2.0, memory=4096MB) ===")
        eval_sb = modal.Sandbox.create(
            app=app,
            image=base_image,
            workdir="/testbed",
            timeout=300,
            cpu=2.0,
            memory=4096,
            env={
                "PATH": "/opt/miniconda3/envs/testbed/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
            },
        )
        try:
            write_remote_b64_file(eval_sb, "/tmp/model.patch", model_patch)
            write_remote_b64_file(eval_sb, "/tmp/test.patch", test_patch)

            test_modules = extract_django_test_modules(fail_to_pass + pass_to_pass)
            if not test_modules:
                test_modules = ["auth_tests.test_validators"]
            modules_arg = " ".join(test_modules)

            eval_script = (
                "set -e\n"
                'export PATH="/opt/miniconda3/envs/testbed/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"\n'
                f"git checkout -f {base_commit}\n"
                "git clean -fd\n"
                "git apply --verbose /tmp/model.patch\n"
                "git apply --verbose /tmp/test.patch || git apply --3way /tmp/test.patch || patch --batch --fuzz=5 -p1 -i /tmp/test.patch\n"
                f"/opt/miniconda3/envs/testbed/bin/python ./tests/runtests.py --verbosity 2 --settings=test_sqlite --parallel 1 {modules_arg}\n"
            )
            eval_proc = eval_sb.exec("sh", "-c", eval_script, timeout=280)
            eval_rc, eval_out, eval_err = stream_process_output(eval_proc)
            combined_eval = f"{eval_out}\n{eval_err}"
            (run_dir / "eval_output.log").write_text(combined_eval, encoding="utf-8")

            f2p_res = parse_django_test_results(combined_eval, fail_to_pass)
            p2p_res = parse_django_test_results(combined_eval, pass_to_pass)
            resolved = (
                eval_rc == 0
                and len(f2p_res["passed"]) == len(fail_to_pass)
                and len(p2p_res["passed"]) == len(pass_to_pass)
                and not f2p_res["failed"]
                and not p2p_res["failed"]
            )
            eval_summary = {
                "evaluated": True,
                "exit_code": eval_rc,
                "test_modules": test_modules,
                "fail_to_pass": {
                    "total": len(fail_to_pass),
                    "passed": len(f2p_res["passed"]),
                    "failed": f2p_res["failed"],
                    "missing": f2p_res["missing"],
                },
                "pass_to_pass": {
                    "total": len(pass_to_pass),
                    "passed": len(p2p_res["passed"]),
                    "failed": p2p_res["failed"],
                    "missing": p2p_res["missing"],
                },
                "resolved": resolved,
            }
        finally:
            print("[Sandbox] Terminating Evaluation Sandbox...")
            eval_sb.terminate()
    else:
        print("\n=== [5/6] Skipping Clean Evaluation (empty model_patch) ===")

    print("\n=== [6/6] Post-Run Modal Billing Summary ===")
    post_billing = run_billing_summary(args.modal_bin)
    print(post_billing)
    assert_zero_billed_cost(post_billing, "POST-RUN")

    report = {
        "instance_id": args.instance_id,
        "image": used_image_tag,
        "profile": args.profile,
        "model": args.model,
        "max_turns": args.max_turns,
        "solver_rc": solver_rc,
        "solver_elapsed_sec": round(solve_elapsed, 2),
        "audit": audit,
        "patch_bytes": len(model_patch),
        "eval_summary": eval_summary,
        "pre_billing": pre_billing,
        "post_billing": post_billing,
    }
    (run_dir / "canary_summary.json").write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8")
    print("\n=== CANARY SUMMARY JSON ===")
    print(json.dumps(report, indent=2, ensure_ascii=False))

    return 0 if (eval_summary["resolved"] and audit["cloud_osint_count"] == 0) else 1


if __name__ == "__main__":
    raise SystemExit(main())
