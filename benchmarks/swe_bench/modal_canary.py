#!/usr/bin/env python3
"""
Dalembert x EnginEdge SWE-bench 1-Task Modal Canary Runner (Zero-Extra-Bill Guarded).

Supports all 12 SWE-bench_Verified Python repositories via `eval_specs` and exposes
a reusable `execute_instance` worker for `modal_batch.py`.

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
from typing import Any

_REPO_ROOT = str(Path(__file__).resolve().parents[2])
if _REPO_ROOT not in sys.path:
    sys.path.insert(0, _REPO_ROOT)

try:
    from benchmarks.swe_bench import eval_specs
except ImportError:
    import eval_specs  # type: ignore[no-redef]

DEFAULT_WS_URL = "wss://dalembert-production.up.railway.app"
DEFAULT_ENGINEDGE_BIN = "/root/Projects/EnginEdge/target/release/enginedge"
DEFAULT_MODAL_BIN = "/root/.local/bin/modal"
DEFAULT_PARQUET_PATH = "/tmp/swebench_verified.parquet"
CONTAINER_ENV_PATH = (
    "/opt/miniconda3/envs/testbed/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
)
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


class BinaryCompatibilityError(RuntimeError):
    """Raised when the mounted `enginedge` binary cannot execute inside the container."""


def _import_modal() -> Any:
    import modal  # type: ignore[import-not-found]

    return modal


def _normalize_str_list(val: Any) -> list[str]:
    if val is None:
        return []
    if isinstance(val, str):
        stripped = val.strip()
        if not stripped:
            return []
        try:
            parsed = json.loads(stripped)
            if isinstance(parsed, list):
                return [str(item) for item in parsed]
        except json.JSONDecodeError:
            pass
        return [stripped]
    if isinstance(val, (list, tuple)):
        return [str(item) for item in val]
    return [str(val)]


def normalize_instance_row(row: dict[str, Any]) -> dict[str, Any]:
    """Normalize a raw SWE-bench dataset row in-place / copy for runner consumption."""
    normalized = dict(row)
    for key in ("FAIL_TO_PASS", "PASS_TO_PASS"):
        normalized[key] = _normalize_str_list(normalized.get(key))
    normalized["repo"] = eval_specs.infer_repo(normalized)
    return normalized


def run_billing_summary(modal_bin: str) -> str:
    proc = subprocess.run([modal_bin, "billing", "summary"], text=True, capture_output=True)
    output = (proc.stdout + proc.stderr).strip()
    if proc.returncode != 0:
        raise RuntimeError(f"modal billing summary failed (rc={proc.returncode}):\n{output}")
    return output


def assert_zero_billed_cost(summary_text: str, phase: str) -> None:
    clean_text = eval_specs.strip_ansi(summary_text)
    if "Billed Cost:    $0.00" not in clean_text and not re.search(
        r"Billed\s+Cost\s*[:│|]?\s*\$?0\.00\b", clean_text
    ):
        raise RuntimeError(
            f"[{phase}] Guardrail violation: Billed Cost is not $0.00!\n{summary_text}"
        )


def load_swebench_instance(instance_id: str, parquet_path: Path) -> dict[str, Any]:
    suffix = parquet_path.suffix.lower()
    if suffix in (".json", ".jsonl"):
        if not parquet_path.is_file():
            raise FileNotFoundError(f"Dataset fixture not found: {parquet_path}")
        raw_text = parquet_path.read_text(encoding="utf-8")
        if suffix == ".jsonl":
            rows = [json.loads(line) for line in raw_text.splitlines() if line.strip()]
        else:
            payload = json.loads(raw_text)
            rows = payload["rows"] if isinstance(payload, dict) and "rows" in payload else payload
        for item in rows:
            if item.get("instance_id") == instance_id:
                return normalize_instance_row(item)
        raise RuntimeError(f"Instance '{instance_id}' not found in {parquet_path}")

    import pyarrow.compute as pc  # type: ignore[import-not-found]
    import pyarrow.parquet as pq  # type: ignore[import-not-found]

    if not parquet_path.is_file():
        print(f"[Dataset] Downloading SWE-bench_Verified parquet to {parquet_path}...")
        parquet_path.parent.mkdir(parents=True, exist_ok=True)
        urllib.request.urlretrieve(PARQUET_URL, str(parquet_path))

    table = pq.read_table(str(parquet_path))
    filtered = table.filter(pc.equal(table["instance_id"], instance_id))
    rows = filtered.to_pylist()
    if not rows:
        raise RuntimeError(f"Instance '{instance_id}' not found in {parquet_path}")
    return normalize_instance_row(rows[0])


def candidate_images_for(instance_id: str) -> list[str]:
    dockerhub_id = instance_id.replace("__", "_1776_")
    return [
        f"ghcr.io/epoch-research/swe-bench.eval.x86_64.{instance_id}:latest",
        f"swebench/sweb.eval.x86_64.{dockerhub_id}:latest",
    ]


def stream_process_output(proc: Any, tag: str = "") -> tuple[int, str, str]:
    stdout_chunks: list[str] = []
    stderr_chunks: list[str] = []
    tag_prefix = f"[{tag}] " if tag else ""

    def reader(pipe: Any, chunks: list[str], stream_label: str) -> None:
        for line in pipe:
            chunks.append(line)
            print(f"{tag_prefix}{stream_label}{line}", end="", flush=True)

    t_out = threading.Thread(
        target=reader, args=(proc.stdout, stdout_chunks, "[OUT] "), daemon=True
    )
    t_err = threading.Thread(
        target=reader, args=(proc.stderr, stderr_chunks, "[ERR] "), daemon=True
    )
    t_out.start()
    t_err.start()
    proc.wait()
    t_out.join(timeout=5)
    t_err.join(timeout=5)
    return proc.returncode, "".join(stdout_chunks), "".join(stderr_chunks)


def audit_logs(stdout_text: str, stderr_text: str) -> dict[str, Any]:
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


def write_remote_b64_file(sb: Any, remote_path: str, content: str) -> None:
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
    """Backward-compatible wrapper around `eval_specs.extract_test_directives`."""
    return eval_specs.extract_test_directives(
        "django/django",
        "",
        fail_to_pass=test_names,
        pass_to_pass=[],
    )


def parse_django_test_results(output: str, expected_tests: list[str]) -> dict[str, Any]:
    """Backward-compatible wrapper around `eval_specs.grade_eval_output` for Django."""
    graded = eval_specs.grade_eval_output(
        repo="django/django",
        output=output,
        fail_to_pass=expected_tests,
        pass_to_pass=[],
        exit_code=0,
    )
    f2p = graded["fail_to_pass"]
    passed_set = set(expected_tests) - set(f2p["failed"]) - set(f2p["missing"])
    return {
        "passed": [t for t in expected_tests if t in passed_set],
        "failed": f2p["failed"],
        "missing": f2p["missing"],
    }


def create_solver_sandbox(
    app: Any,
    instance_id: str,
    enginedge_bin: str,
    ws_url: str,
    auth_token: str,
    sandbox_timeout: int,
) -> tuple[Any, str, Any]:
    modal = _import_modal()
    last_error = None
    for image_tag in candidate_images_for(instance_id):
        print(f"[Sandbox:{instance_id}] Attempting base image: {image_tag}")
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
                env={"PATH": CONTAINER_ENV_PATH},
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
            print(f"[Sandbox:{instance_id}] Failed with image {image_tag}: {exc}")
    raise RuntimeError(f"All candidate images failed for {instance_id}: {last_error}")


def execute_instance(
    instance: dict[str, Any],
    *,
    app: Any,
    enginedge_bin: str,
    ws_url: str,
    auth_token: str,
    profile: str,
    model: str,
    max_turns: int,
    agent_timeout: int,
    sandbox_timeout: int,
    run_dir: Path,
) -> dict[str, Any]:
    """
    Execute a single SWE-bench_Verified instance across Solver + Clean Evaluation Modal
    Sandboxes using repository-aware evaluation specifications from `eval_specs`.
    """
    modal = _import_modal()
    normalized = normalize_instance_row(instance)
    instance_id = str(normalized["instance_id"])
    repo = normalized["repo"]
    version = normalized.get("version")
    problem_statement = str(normalized["problem_statement"])
    test_patch = str(normalized.get("test_patch") or "")
    base_commit = str(normalized["base_commit"])
    fail_to_pass = list(normalized["FAIL_TO_PASS"])
    pass_to_pass = list(normalized["PASS_TO_PASS"])

    run_dir.mkdir(parents=True, exist_ok=True)

    test_directives = eval_specs.extract_test_directives(
        repo,
        test_patch,
        fail_to_pass=fail_to_pass,
        pass_to_pass=pass_to_pass,
    )
    eval_cmd = eval_specs.build_eval_command(
        repo,
        test_patch,
        fail_to_pass=fail_to_pass,
        pass_to_pass=pass_to_pass,
        version=version,
    )

    model_patch = ""
    solver_rc = -1
    solver_stdout = ""
    solver_stderr = ""

    print(
        f"\n[Solver:{instance_id}] Launching Solver Modal Sandbox "
        f"(repo={repo}, timeout={sandbox_timeout}s, cpu=2.0, memory=4096MB)"
    )
    t0 = time.time()
    sb, used_image_tag, base_image = create_solver_sandbox(
        app=app,
        instance_id=instance_id,
        enginedge_bin=enginedge_bin,
        ws_url=ws_url,
        auth_token=auth_token,
        sandbox_timeout=sandbox_timeout,
    )
    try:
        ver_proc = sb.exec("/usr/local/bin/enginedge", "--version")
        ver_out = ver_proc.stdout.read()
        ver_err = ver_proc.stderr.read()
        ver_proc.wait()
        print(
            f"[Binary Check:{instance_id}] enginedge --version "
            f"(rc={ver_proc.returncode}): {(ver_out + ver_err).strip()}"
        )
        if ver_proc.returncode != 0:
            ldd_proc = sb.exec(
                "sh",
                "-c",
                "ldd /usr/local/bin/enginedge || true; cat /etc/os-release || true",
            )
            diag = ldd_proc.stdout.read() + ldd_proc.stderr.read()
            ldd_proc.wait()
            print(f"[Binary Mismatch Diagnostics:{instance_id}]\n{diag}")
            raise BinaryCompatibilityError(
                f"enginedge --version failed inside {used_image_tag} (rc={ver_proc.returncode})"
            )

        write_remote_b64_file(sb, "/tmp/problem_statement.txt", problem_statement)

        solve_script = (
            f'export PATH="{CONTAINER_ENV_PATH}"\n'
            'PROBLEM_TEXT="$(cat /tmp/problem_statement.txt)"\n'
            'exec /usr/local/bin/enginedge --mode eval --hub-url "$DALEMBERT_WS_URL" run '
            f'--task-name "swe_{instance_id}" '
            "--workflow-mode swe_bench "
            "--no-cloud-tools "
            "--disabled-tools ping,echo "
            f'--profile "{profile}" '
            f'--model "{model}" '
            f"--max-turns {max_turns} "
            f"--timeout {agent_timeout} "
            '--task "$PROBLEM_TEXT"\n'
        )
        print(
            f"[Solver:{instance_id}] Running enginedge "
            f"(profile={profile}, model={model}, max_turns={max_turns}, timeout={agent_timeout}s)..."
        )
        solve_proc = sb.exec("sh", "-c", solve_script, timeout=sandbox_timeout)
        solver_rc, solver_stdout, solver_stderr = stream_process_output(solve_proc, tag=instance_id)

        diff_proc = sb.exec("git", "-C", "/testbed", "diff")
        model_patch = diff_proc.stdout.read()
        diff_err = diff_proc.stderr.read()
        diff_proc.wait()
        if diff_err.strip():
            print(f"[git diff stderr:{instance_id}] {diff_err.strip()}")

        status_proc = sb.exec("git", "-C", "/testbed", "status", "--short")
        print(f"[git status --short:{instance_id}]\n{status_proc.stdout.read().strip()}")
        status_proc.wait()
    finally:
        print(f"[Sandbox:{instance_id}] Terminating Solver Sandbox...")
        sb.terminate()

    solve_elapsed = time.time() - t0
    (run_dir / "enginedge_stdout.log").write_text(solver_stdout, encoding="utf-8")
    (run_dir / "enginedge_stderr.log").write_text(solver_stderr, encoding="utf-8")
    (run_dir / "model.patch").write_text(model_patch, encoding="utf-8")

    audit = audit_logs(solver_stdout, solver_stderr)
    print(f"\n[Audit:{instance_id}] elapsed={solve_elapsed:.1f}s, rc={solver_rc}")
    print(f"Image used: {used_image_tag}")
    print(f"Phases observed: {audit['phases_seen']}")
    print(f"Cloud OSINT tool hits: {audit['cloud_osint_count']}")
    print(f"Patch bytes: {len(model_patch)}")

    eval_summary: dict[str, Any] = {
        "evaluated": False,
        "exit_code": None,
        "runner_exit_zero": False,
        "test_directives": test_directives,
        "fail_to_pass": None,
        "pass_to_pass": None,
        "resolved": False,
    }
    eval_elapsed = 0.0

    if model_patch.strip():
        print(
            f"\n[Eval:{instance_id}] Launching Clean Official Evaluation Sandbox "
            "(timeout=300s, cpu=2.0, memory=4096MB)"
        )
        t_eval = time.time()
        eval_sb = modal.Sandbox.create(
            app=app,
            image=base_image,
            workdir="/testbed",
            timeout=300,
            cpu=2.0,
            memory=4096,
            env={"PATH": CONTAINER_ENV_PATH},
        )
        try:
            write_remote_b64_file(eval_sb, "/tmp/model.patch", model_patch)
            write_remote_b64_file(eval_sb, "/tmp/test.patch", test_patch)

            eval_script = (
                "set -e\n"
                f'export PATH="{CONTAINER_ENV_PATH}"\n'
                f"git checkout -f {base_commit}\n"
                "git clean -fd\n"
                "git apply --verbose /tmp/model.patch || git apply --3way /tmp/model.patch || patch --batch --fuzz=5 -p1 -i /tmp/model.patch\n"
                "git apply --verbose /tmp/test.patch || git apply --3way /tmp/test.patch || patch --batch --fuzz=5 -p1 -i /tmp/test.patch\n"
                "set +e\n"
                f"{eval_cmd}\n"
            )
            eval_proc = eval_sb.exec("sh", "-c", eval_script, timeout=280)
            eval_rc, eval_out, eval_err = stream_process_output(eval_proc, tag=f"eval:{instance_id}")
            combined_eval = f"{eval_out}\n{eval_err}"
            (run_dir / "eval_output.log").write_text(combined_eval, encoding="utf-8")

            eval_summary = eval_specs.grade_eval_output(
                repo=repo,
                output=combined_eval,
                fail_to_pass=fail_to_pass,
                pass_to_pass=pass_to_pass,
                exit_code=eval_rc,
                test_directives=test_directives,
            )
            if repo == "django/django":
                eval_summary["test_modules"] = list(test_directives)
        finally:
            print(f"[Sandbox:{instance_id}] Terminating Evaluation Sandbox...")
            eval_sb.terminate()
        eval_elapsed = time.time() - t_eval
    else:
        print(f"\n[Eval:{instance_id}] Skipping Clean Evaluation (empty model_patch)")

    return {
        "instance_id": instance_id,
        "repo": repo,
        "image": used_image_tag,
        "profile": profile,
        "model": model,
        "model_name_or_path": f"dalembert-swe_bench-{model}",
        "model_patch": model_patch,
        "max_turns": max_turns,
        "solver_rc": solver_rc,
        "solver_elapsed_sec": round(solve_elapsed, 2),
        "eval_elapsed_sec": round(eval_elapsed, 2),
        "audit": audit,
        "patch_bytes": len(model_patch),
        "eval_cmd": eval_cmd,
        "eval_summary": eval_summary,
        "resolved": bool(eval_summary.get("resolved", False)),
        "error": None,
    }


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Dalembert x EnginEdge Modal SWE-bench 1-Task Canary"
    )
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
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_arg_parser()
    args = parser.parse_args(argv)

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
    repo = eval_specs.infer_repo(instance)
    print(
        f"Loaded {args.instance_id} (repo={repo}, base_commit={instance['base_commit']}, "
        f"F2P={len(instance['FAIL_TO_PASS'])}, P2P={len(instance['PASS_TO_PASS'])})"
    )

    modal = _import_modal()
    auth_token = os.environ.get("HUB_AUTH_TOKEN", "")
    app = modal.App.lookup("dalembert-swe-bench-canary", create_if_missing=True)

    print("\n=== [3/6 - 5/6] Executing Solver & Clean Evaluation Sandboxes ===")
    try:
        result = execute_instance(
            instance,
            app=app,
            enginedge_bin=args.enginedge_bin,
            ws_url=args.ws_url,
            auth_token=auth_token,
            profile=args.profile,
            model=args.model,
            max_turns=args.max_turns,
            agent_timeout=args.agent_timeout,
            sandbox_timeout=args.sandbox_timeout,
            run_dir=run_dir,
        )
    except BinaryCompatibilityError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2

    prediction_record = {
        "instance_id": result["instance_id"],
        "model_name_or_path": result["model_name_or_path"],
        "model_patch": result["model_patch"],
    }
    pred_path = run_dir / "predictions.jsonl"
    pred_path.write_text(
        json.dumps(prediction_record, ensure_ascii=False) + "\n", encoding="utf-8"
    )

    print("\n=== [6/6] Post-Run Modal Billing Summary ===")
    post_billing = run_billing_summary(args.modal_bin)
    print(post_billing)
    assert_zero_billed_cost(post_billing, "POST-RUN")

    report = {
        "instance_id": result["instance_id"],
        "repo": result["repo"],
        "image": result["image"],
        "profile": result["profile"],
        "model": result["model"],
        "max_turns": result["max_turns"],
        "solver_rc": result["solver_rc"],
        "solver_elapsed_sec": result["solver_elapsed_sec"],
        "audit": result["audit"],
        "patch_bytes": result["patch_bytes"],
        "eval_summary": result["eval_summary"],
        "pre_billing": pre_billing,
        "post_billing": post_billing,
    }
    (run_dir / "canary_summary.json").write_text(
        json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8"
    )
    print("\n=== CANARY SUMMARY JSON ===")
    print(json.dumps(report, indent=2, ensure_ascii=False))

    return 0 if (result["eval_summary"]["resolved"] and result["audit"]["cloud_osint_count"] == 0) else 1


if __name__ == "__main__":
    raise SystemExit(main())
