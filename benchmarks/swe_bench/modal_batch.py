#!/usr/bin/env python3
"""
Dalembert x EnginEdge Multi-Repository SWE-bench Modal Batch Runner.

Features:
  - Supports all 12 SWE-bench_Verified Python repositories via `eval_specs`.
  - Loads `.parquet` (lazy `pyarrow`) as well as offline `.json` / `.jsonl` fixtures.
  - Deterministic `--stratified` + `--seed` round-robin sampling across repositories.
  - Hard-clamped `--concurrency` (1..3), checkpoint `--resume` / `--retry-errors`.
  - Modal Billing Circuit Breaker (`--max-budget-usd`, zero-billed-cost enforcement).
  - Incremental `predictions.jsonl`, `batch_summary.json`, and `REPORT.md` generation.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import datetime as dt
import json
import os
import random
import re
import sys
import threading
import time
import urllib.request
from pathlib import Path
from typing import Any, Callable

_REPO_ROOT = str(Path(__file__).resolve().parents[2])
if _REPO_ROOT not in sys.path:
    sys.path.insert(0, _REPO_ROOT)

try:
    from benchmarks.swe_bench import eval_specs
    from benchmarks.swe_bench.modal_canary import (
        DEFAULT_ENGINEDGE_BIN,
        DEFAULT_MODAL_BIN,
        DEFAULT_PARQUET_PATH,
        DEFAULT_WS_URL,
        PARQUET_URL,
        audit_logs,
        candidate_images_for,
        execute_instance,
        normalize_instance_row,
        run_billing_summary,
    )
except ImportError:
    import eval_specs  # type: ignore[no-redef]
    from modal_canary import (  # type: ignore[no-redef]
        DEFAULT_ENGINEDGE_BIN,
        DEFAULT_MODAL_BIN,
        DEFAULT_PARQUET_PATH,
        DEFAULT_WS_URL,
        PARQUET_URL,
        audit_logs,
        candidate_images_for,
        execute_instance,
        normalize_instance_row,
        run_billing_summary,
    )

MIN_CONCURRENCY = 1
MAX_CONCURRENCY = 3

_CURRENCY_NUMBER_PATTERN = r"([+-]?\s*\$?\s*[+-]?\d[\d,]*(?:\.\d+)?)"
_METERED_COST_RE = re.compile(
    rf"Metered\s+Cost\s*[:│|]?\s*{_CURRENCY_NUMBER_PATTERN}", re.IGNORECASE
)
_CREDITS_RE = re.compile(rf"Credits\s*[:│|]?\s*{_CURRENCY_NUMBER_PATTERN}", re.IGNORECASE)
_BILLED_COST_RE = re.compile(
    rf"Billed\s+Cost\s*[:│|]?\s*{_CURRENCY_NUMBER_PATTERN}", re.IGNORECASE
)


def _import_modal() -> Any:
    import modal  # type: ignore[import-not-found]

    return modal


def clamp_concurrency(val: int) -> int:
    """Hard-clamp batch concurrency to `1..3` with stderr warning if adjusted."""
    if val < MIN_CONCURRENCY:
        print(
            f"[WARN] Requested concurrency={val} is below {MIN_CONCURRENCY}; "
            f"clamping to {MIN_CONCURRENCY}.",
            file=sys.stderr,
        )
        return MIN_CONCURRENCY
    if val > MAX_CONCURRENCY:
        print(
            f"[WARN] Requested concurrency={val} exceeds safety cap {MAX_CONCURRENCY}; "
            f"clamping to {MAX_CONCURRENCY}.",
            file=sys.stderr,
        )
        return MAX_CONCURRENCY
    return val


def _parse_currency_token(raw_token: str) -> float:
    negative = "-" in raw_token
    cleaned = re.sub(r"[^0-9.]", "", raw_token)
    val = float(cleaned)
    result = -val if negative else val
    return 0.0 if result == 0.0 else result


def parse_billing_summary(text: str) -> dict[str, Any]:
    """
    Parse `modal billing summary` CLI output into structured numeric fields:
      `{"metered_cost": float, "credits": float | None, "billed_cost": float}`.
    """
    clean = eval_specs.strip_ansi(text or "")
    billed_match = _BILLED_COST_RE.search(clean)
    if not billed_match:
        raise ValueError(f"Unable to parse 'Billed Cost' from billing summary:\n{clean}")

    metered_match = _METERED_COST_RE.search(clean)
    credits_match = _CREDITS_RE.search(clean)

    metered_cost = _parse_currency_token(metered_match.group(1)) if metered_match else 0.0
    credits = _parse_currency_token(credits_match.group(1)) if credits_match else None
    billed_cost = _parse_currency_token(billed_match.group(1))

    return {
        "metered_cost": metered_cost,
        "credits": credits,
        "billed_cost": billed_cost,
    }


class BillingCircuitBreaker:
    """
    Thread-safe Modal billing guardrail that trips immediately when:
      1. `billed_cost > 0.0` (zero out-of-pocket bill violation), OR
      2. `(current_metered - initial_metered) >= max_budget_usd`.
    """

    def __init__(
        self,
        *,
        max_budget_usd: float = 5.0,
        billing_fetcher: Callable[[], str],
    ) -> None:
        self.max_budget_usd = float(max_budget_usd)
        self._billing_fetcher = billing_fetcher
        self._lock = threading.Lock()
        self.tripped: bool = False
        self.reason: str | None = None
        self.initial_billing: dict[str, Any] | None = None
        self.latest_billing: dict[str, Any] | None = None
        self.metered_delta_usd: float = 0.0

    def check(self, phase: str = "check") -> dict[str, Any]:
        with self._lock:
            try:
                raw_text = self._billing_fetcher()
                parsed = parse_billing_summary(raw_text)
            except Exception as exc:
                self.tripped = True
                if self.reason is None:
                    self.reason = f"[{phase}] Billing check error: {exc}"
                return self.to_dict()

            if self.initial_billing is None:
                self.initial_billing = parsed
            self.latest_billing = parsed
            self.metered_delta_usd = round(
                parsed["metered_cost"] - self.initial_billing["metered_cost"], 6
            )

            if parsed["billed_cost"] > 0.0:
                self.tripped = True
                if self.reason is None:
                    self.reason = (
                        f"[{phase}] Guardrail tripped: Billed Cost is "
                        f"${parsed['billed_cost']:.2f} (> $0.00)"
                    )
            elif self.metered_delta_usd >= self.max_budget_usd:
                self.tripped = True
                if self.reason is None:
                    self.reason = (
                        f"[{phase}] Guardrail tripped: Metered spend delta "
                        f"${self.metered_delta_usd:.2f} >= max budget ${self.max_budget_usd:.2f}"
                    )

            return self.to_dict()

    def to_dict(self) -> dict[str, Any]:
        return {
            "tripped": self.tripped,
            "reason": self.reason,
            "max_budget_usd": self.max_budget_usd,
            "initial_billing": self.initial_billing,
            "latest_billing": self.latest_billing,
            "metered_delta_usd": self.metered_delta_usd,
        }


def load_swebench_dataset(parquet_path: Path) -> list[dict[str, Any]]:
    """
    Load SWE-bench dataset rows from `.parquet` (lazy `pyarrow.parquet`) or local
    `.json` / `.jsonl` fixtures (stdlib `json`).
    """
    suffix = parquet_path.suffix.lower()
    if suffix in (".json", ".jsonl"):
        if not parquet_path.is_file():
            raise FileNotFoundError(f"Dataset fixture not found: {parquet_path}")
        content = parquet_path.read_text(encoding="utf-8")
        if suffix == ".jsonl":
            raw_rows = [json.loads(line) for line in content.splitlines() if line.strip()]
        else:
            parsed = json.loads(content)
            if isinstance(parsed, dict) and "rows" in parsed:
                raw_rows = parsed["rows"]
            elif isinstance(parsed, list):
                raw_rows = parsed
            else:
                raw_rows = [parsed]
        return [normalize_instance_row(r) for r in raw_rows]

    import pyarrow.parquet as pq  # type: ignore[import-not-found]

    if not parquet_path.is_file():
        print(f"[Dataset] Downloading SWE-bench_Verified parquet to {parquet_path}...")
        parquet_path.parent.mkdir(parents=True, exist_ok=True)
        urllib.request.urlretrieve(PARQUET_URL, str(parquet_path))

    table = pq.read_table(str(parquet_path))
    return [normalize_instance_row(r) for r in table.to_pylist()]


def parse_instance_spec(instances_arg: str | list[str] | None) -> list[str]:
    if not instances_arg:
        return []
    if isinstance(instances_arg, list):
        raw_tokens = instances_arg
    elif instances_arg.startswith("@"):
        file_path = Path(instances_arg[1:])
        raw_tokens = []
        for line in file_path.read_text(encoding="utf-8").splitlines():
            clean_line = line.split("#", 1)[0].strip()
            if clean_line:
                raw_tokens.extend(re.split(r"[,\s]+", clean_line))
    else:
        raw_tokens = instances_arg.split(",")

    deduped: list[str] = []
    for tok in raw_tokens:
        item = tok.strip()
        if item and item not in deduped:
            deduped.append(item)
    return deduped


def parse_repo_spec(repo_arg: str | list[str] | None) -> list[str]:
    if not repo_arg:
        return []
    raw_items = repo_arg if isinstance(repo_arg, list) else repo_arg.split(",")
    deduped: list[str] = []
    for tok in raw_items:
        item = tok.strip()
        if item and item not in deduped:
            deduped.append(item)
    return deduped


def select_instances(
    dataset: list[dict[str, Any]],
    *,
    instances: str | list[str] | None = None,
    repos: str | list[str] | None = None,
    stratified: bool = False,
    seed: int = 42,
    limit: int | None = 10,
) -> list[dict[str, Any]]:
    """
    Filter and deterministically sample SWE-bench instances.

    When `stratified=True`, each distinct repo's sorted instances are shuffled using
    `random.Random(seed)` and selected round-robin across sorted repo names up to `limit`.
    """
    instance_ids = parse_instance_spec(instances)
    repo_filters = set(parse_repo_spec(repos))

    candidates = [normalize_instance_row(r) for r in dataset]

    if instance_ids:
        by_id = {str(r["instance_id"]): r for r in candidates}
        candidates = [by_id[iid] for iid in instance_ids if iid in by_id]

    if repo_filters:
        candidates = [r for r in candidates if eval_specs.infer_repo(r) in repo_filters]

    effective_limit = limit if (limit is not None and limit > 0) else len(candidates)
    if effective_limit == 0 or not candidates:
        return []

    if not stratified:
        return candidates[:effective_limit]

    rng = random.Random(seed)
    by_repo: dict[str, list[dict[str, Any]]] = {}
    for row in candidates:
        repo_slug = eval_specs.infer_repo(row)
        by_repo.setdefault(repo_slug, []).append(row)

    repo_buckets: list[list[dict[str, Any]]] = []
    for repo_slug in sorted(by_repo.keys()):
        bucket = sorted(by_repo[repo_slug], key=lambda item: str(item["instance_id"]))
        rng.shuffle(bucket)
        repo_buckets.append(bucket)

    selected: list[dict[str, Any]] = []
    round_idx = 0
    while len(selected) < effective_limit:
        added_in_round = False
        for bucket in repo_buckets:
            if round_idx < len(bucket):
                selected.append(bucket[round_idx])
                added_in_round = True
                if len(selected) >= effective_limit:
                    break
        if not added_in_round:
            break
        round_idx += 1

    return selected


def should_skip_instance(
    summary_path: Path,
    *,
    resume: bool = True,
    retry_errors: bool = False,
) -> tuple[bool, dict[str, Any] | None]:
    """
    Determine whether an instance checkpoint at `summary_path` should be skipped on resume.

    Returns `(skip, cached_summary)`.
    """
    if not resume or not summary_path.is_file():
        return False, None
    try:
        cached = json.loads(summary_path.read_text(encoding="utf-8"))
        if not isinstance(cached, dict):
            return False, None
    except (OSError, json.JSONDecodeError):
        return False, None

    has_error = bool(cached.get("error")) or cached.get("solver_rc", -1) != 0
    if retry_errors and has_error:
        return False, cached
    return True, cached


def _resolve_resume_status_label(
    summary_path: Path,
    *,
    resume: bool,
    retry_errors: bool,
) -> str:
    if not resume or not summary_path.is_file():
        return "RUN"
    skip, cached = should_skip_instance(
        summary_path, resume=resume, retry_errors=retry_errors
    )
    if skip:
        return "SKIP (cached)"
    if cached is not None:
        return "RETRY (error)"
    return "RUN"


def render_dry_run_table(
    selected: list[dict[str, Any]],
    *,
    batch_dir: Path,
    resume: bool = True,
    retry_errors: bool = False,
) -> str:
    """Format a preview table of selected instances for `--dry-run` without touching Modal."""
    headers = ("instance_id", "repo", "primary_image", "eval_cmd", "resume_status")
    rows: list[tuple[str, str, str, str, str]] = []

    for inst in selected:
        iid = str(inst["instance_id"])
        repo = eval_specs.infer_repo(inst)
        primary_image = candidate_images_for(iid)[0]
        eval_cmd = eval_specs.build_eval_command(
            repo,
            str(inst.get("test_patch") or ""),
            fail_to_pass=inst.get("FAIL_TO_PASS"),
            pass_to_pass=inst.get("PASS_TO_PASS"),
            version=inst.get("version"),
        )
        summary_path = batch_dir / "instances" / iid / "summary.json"
        status_label = _resolve_resume_status_label(
            summary_path, resume=resume, retry_errors=retry_errors
        )
        rows.append((iid, repo, primary_image, eval_cmd, status_label))

    widths = [len(h) for h in headers]
    for r in rows:
        for idx, cell in enumerate(r):
            widths[idx] = max(widths[idx], len(cell))

    def fmt_row(cols: tuple[str, ...]) -> str:
        return " | ".join(col.ljust(widths[i]) for i, col in enumerate(cols))

    sep = "-+-".join("-" * w for w in widths)
    lines = [
        f"Dry-Run Batch Preview ({len(rows)} instances) -> {batch_dir}",
        fmt_row(headers),
        sep,
    ]
    for r in rows:
        lines.append(fmt_row(r))
    return "\n".join(lines)


def _build_batch_summary_dict(
    *,
    batch_name: str,
    profile: str,
    model: str,
    selected_instances: list[dict[str, Any]],
    completed_by_id: dict[str, dict[str, Any]],
    resumed_ids: set[str],
    elapsed_sec: float,
    billing_state: dict[str, Any],
) -> dict[str, Any]:
    ordered_completed: list[dict[str, Any]] = []
    for inst in selected_instances:
        iid = str(inst["instance_id"])
        if iid in completed_by_id:
            ordered_completed.append(completed_by_id[iid])

    completed_count = len(ordered_completed)
    resumed_count = sum(1 for s in ordered_completed if s.get("instance_id") in resumed_ids)
    executed_count = completed_count - resumed_count
    resolved_count = sum(
        1
        for s in ordered_completed
        if bool(s.get("resolved") or (s.get("eval_summary") or {}).get("resolved"))
    )
    evaluated_count = sum(
        1 for s in ordered_completed if bool((s.get("eval_summary") or {}).get("evaluated"))
    )
    error_count = sum(
        1 for s in ordered_completed if bool(s.get("error")) or s.get("solver_rc", 0) != 0
    )

    per_repo: dict[str, dict[str, Any]] = {}
    phase_counts = {"locate": 0, "reproduce": 0, "patch_and_verify": 0, "full_3_phase_count": 0}
    cloud_osint_violations = 0

    for summary in ordered_completed:
        repo = str(summary.get("repo") or eval_specs.infer_repo(summary))
        bucket = per_repo.setdefault(
            repo, {"total": 0, "evaluated": 0, "resolved": 0, "errors": 0, "pass_at_1": 0.0}
        )
        bucket["total"] += 1
        eval_sum = summary.get("eval_summary") or {}
        is_eval = bool(eval_sum.get("evaluated"))
        is_res = bool(summary.get("resolved") or eval_sum.get("resolved"))
        is_err = bool(summary.get("error")) or summary.get("solver_rc", 0) != 0
        if is_eval:
            bucket["evaluated"] += 1
        if is_res:
            bucket["resolved"] += 1
        if is_err:
            bucket["errors"] += 1

        audit = summary.get("audit") or audit_logs("", "")
        phases = set(audit.get("phases_seen") or [])
        for p_name in ("locate", "reproduce", "patch_and_verify"):
            if p_name in phases:
                phase_counts[p_name] += 1
        if {"locate", "reproduce", "patch_and_verify"}.issubset(phases):
            phase_counts["full_3_phase_count"] += 1
        cloud_osint_violations += int(audit.get("cloud_osint_count") or 0)

    for repo, bucket in per_repo.items():
        bucket["pass_at_1"] = (
            round(bucket["resolved"] / bucket["total"], 4) if bucket["total"] else 0.0
        )

    pass_at_1 = round(resolved_count / completed_count, 4) if completed_count else 0.0
    selected_total = len(selected_instances)
    pass_at_1_selected = round(resolved_count / selected_total, 4) if selected_total else 0.0

    instance_rows = []
    for summary in ordered_completed:
        iid = str(summary["instance_id"])
        eval_sum = summary.get("eval_summary") or {}
        audit = summary.get("audit") or {}
        instance_rows.append(
            {
                "instance_id": iid,
                "repo": summary.get("repo") or eval_specs.infer_repo(iid),
                "resumed": iid in resumed_ids,
                "solver_rc": summary.get("solver_rc"),
                "patch_bytes": summary.get("patch_bytes", 0),
                "evaluated": bool(eval_sum.get("evaluated")),
                "resolved": bool(summary.get("resolved") or eval_sum.get("resolved")),
                "phases_seen": audit.get("phases_seen", []),
                "cloud_osint_count": audit.get("cloud_osint_count", 0),
                "solver_elapsed_sec": summary.get("solver_elapsed_sec", 0.0),
                "error": summary.get("error"),
            }
        )

    return {
        "batch_name": batch_name,
        "profile": profile,
        "model": model,
        "selected_count": selected_total,
        "completed_count": completed_count,
        "resumed_count": resumed_count,
        "executed_count": executed_count,
        "halted_count": max(0, selected_total - completed_count),
        "evaluated_count": evaluated_count,
        "resolved_count": resolved_count,
        "error_count": error_count,
        "pass_at_1": pass_at_1,
        "pass_at_1_selected": pass_at_1_selected,
        "per_repo": dict(sorted(per_repo.items())),
        "phase_stats": phase_counts,
        "cloud_osint_violations": cloud_osint_violations,
        "elapsed_sec": round(elapsed_sec, 2),
        "billing": billing_state,
        "instances": instance_rows,
    }


def render_markdown_report(batch_summary: dict[str, Any]) -> str:
    """Render clean GitHub-flavored Markdown report (`REPORT.md`) from `batch_summary`."""
    billing = batch_summary.get("billing") or {}
    init_bill = billing.get("initial_billing") or {}
    last_bill = billing.get("latest_billing") or {}
    breaker_status = "TRIPPED" if billing.get("tripped") else "OK"
    breaker_reason = billing.get("reason") or "None"

    def fmt_usd(val: Any) -> str:
        return f"${float(val):.2f}" if isinstance(val, (int, float)) else "N/A"

    lines = [
        f"# SWE-bench Batch Report: `{batch_summary['batch_name']}`",
        "",
        "## Summary Metrics",
        "",
        "| Metric | Value |",
        "| :--- | :--- |",
        f"| Profile / Model | `{batch_summary['profile']}` / `{batch_summary['model']}` |",
        f"| Selected / Completed | {batch_summary['selected_count']} / {batch_summary['completed_count']} (resumed: {batch_summary['resumed_count']}, halted: {batch_summary['halted_count']}) |",
        f"| Evaluated | {batch_summary['evaluated_count']} |",
        f"| Resolved | **{batch_summary['resolved_count']}** |",
        f"| Pass@1 (Completed) | **{batch_summary['pass_at_1'] * 100:.1f}%** ({batch_summary['resolved_count']}/{batch_summary['completed_count']}) |",
        f"| Errors | {batch_summary['error_count']} |",
        f"| Cloud OSINT Violations | {batch_summary['cloud_osint_violations']} |",
        f"| Batch Elapsed (s) | {batch_summary['elapsed_sec']:.2f}s |",
        "",
        "## Billing Guardrail Status",
        "",
        "| Guardrail Field | Value |",
        "| :--- | :--- |",
        f"| Circuit Breaker | **{breaker_status}** |",
        f"| Trip Reason | {breaker_reason} |",
        f"| Max Budget (USD) | {fmt_usd(billing.get('max_budget_usd'))} |",
        f"| Initial Metered Cost | {fmt_usd(init_bill.get('metered_cost'))} |",
        f"| Latest Metered Cost | {fmt_usd(last_bill.get('metered_cost'))} |",
        f"| Metered Delta (USD) | {fmt_usd(billing.get('metered_delta_usd'))} |",
        f"| Latest Billed Cost | {fmt_usd(last_bill.get('billed_cost'))} |",
        "",
        "## Per-Repository Pass@1",
        "",
        "| Repository | Completed | Evaluated | Resolved | Errors | Pass@1 |",
        "| :--- | ---: | ---: | ---: | ---: | ---: |",
    ]

    per_repo = batch_summary.get("per_repo") or {}
    if per_repo:
        for repo, stats in per_repo.items():
            lines.append(
                f"| `{repo}` | {stats['total']} | {stats['evaluated']} | "
                f"{stats['resolved']} | {stats['errors']} | {stats['pass_at_1'] * 100:.1f}% |"
            )
    else:
        lines.append("| _None_ | 0 | 0 | 0 | 0 | 0.0% |")

    lines.extend(
        [
            "",
            "## Per-Instance Results",
            "",
            "| Instance ID | Repository | Source | Resolved | Patch Bytes | Phases | Elapsed (s) | Error |",
            "| :--- | :--- | :--- | :---: | ---: | :--- | ---: | :--- |",
        ]
    )

    instances = batch_summary.get("instances") or []
    if instances:
        for row in instances:
            src = "resumed" if row.get("resumed") else "executed"
            res_mark = "YES" if row.get("resolved") else "NO"
            phases_str = " -> ".join(row.get("phases_seen") or []) or "-"
            err_str = str(row.get("error") or "-").replace("|", "\\|").replace("\n", " ")[:80]
            lines.append(
                f"| `{row['instance_id']}` | `{row['repo']}` | {src} | {res_mark} | "
                f"{row.get('patch_bytes', 0)} | {phases_str} | "
                f"{float(row.get('solver_elapsed_sec') or 0.0):.2f} | {err_str} |"
            )
    else:
        lines.append("| _None_ | - | - | - | 0 | - | 0.00 | - |")

    lines.append("")
    return "\n".join(lines)


def _write_batch_artifacts(
    *,
    batch_dir: Path,
    batch_name: str,
    profile: str,
    model: str,
    selected_instances: list[dict[str, Any]],
    completed_by_id: dict[str, dict[str, Any]],
    resumed_ids: set[str],
    elapsed_sec: float,
    billing_state: dict[str, Any],
) -> dict[str, Any]:
    batch_dir.mkdir(parents=True, exist_ok=True)

    pred_lines: list[str] = []
    for inst in selected_instances:
        iid = str(inst["instance_id"])
        if iid not in completed_by_id:
            continue
        summary = completed_by_id[iid]
        model_patch = summary.get("model_patch")
        if model_patch is None:
            patch_file = batch_dir / "instances" / iid / "model.patch"
            model_patch = (
                patch_file.read_text(encoding="utf-8") if patch_file.is_file() else ""
            )
        pred_record = {
            "instance_id": iid,
            "model_name_or_path": summary.get("model_name_or_path")
            or f"dalembert-swe_bench-{model}",
            "model_patch": model_patch,
        }
        pred_lines.append(json.dumps(pred_record, ensure_ascii=False))

    (batch_dir / "predictions.jsonl").write_text(
        ("\n".join(pred_lines) + "\n") if pred_lines else "",
        encoding="utf-8",
    )

    batch_summary = _build_batch_summary_dict(
        batch_name=batch_name,
        profile=profile,
        model=model,
        selected_instances=selected_instances,
        completed_by_id=completed_by_id,
        resumed_ids=resumed_ids,
        elapsed_sec=elapsed_sec,
        billing_state=billing_state,
    )
    (batch_dir / "batch_summary.json").write_text(
        json.dumps(batch_summary, indent=2, ensure_ascii=False),
        encoding="utf-8",
    )
    (batch_dir / "REPORT.md").write_text(
        render_markdown_report(batch_summary),
        encoding="utf-8",
    )
    return batch_summary


def run_batch(
    selected_instances: list[dict[str, Any]],
    *,
    batch_dir: Path,
    batch_name: str,
    profile: str = "default",
    model: str = "hy4",
    max_turns: int = 45,
    agent_timeout: int = 540,
    sandbox_timeout: int = 600,
    concurrency: int = 1,
    resume: bool = True,
    retry_errors: bool = False,
    max_budget_usd: float = 5.0,
    ws_url: str = DEFAULT_WS_URL,
    auth_token: str = "",
    enginedge_bin: str = DEFAULT_ENGINEDGE_BIN,
    modal_bin: str = DEFAULT_MODAL_BIN,
    app: Any = None,
    executor: Callable[..., dict[str, Any]] | None = None,
    billing_fetcher: Callable[[], str] | None = None,
) -> dict[str, Any]:
    """
    Run a batch of SWE-bench instances with checkpoint resume, bounded concurrency,
    Modal billing circuit breaker, and incremental artifact generation.
    """
    effective_concurrency = clamp_concurrency(concurrency)
    inst_executor = executor or execute_instance
    bill_fn = billing_fetcher or (lambda: run_billing_summary(modal_bin))
    breaker = BillingCircuitBreaker(max_budget_usd=max_budget_usd, billing_fetcher=bill_fn)

    t_start = time.time()
    batch_dir.mkdir(parents=True, exist_ok=True)
    instances_root = batch_dir / "instances"
    instances_root.mkdir(parents=True, exist_ok=True)

    completed_by_id: dict[str, dict[str, Any]] = {}
    resumed_ids: set[str] = set()
    pending_instances: list[dict[str, Any]] = []

    for inst in selected_instances:
        iid = str(inst["instance_id"])
        summary_path = instances_root / iid / "summary.json"
        skip, cached = should_skip_instance(
            summary_path, resume=resume, retry_errors=retry_errors
        )
        if skip and cached is not None:
            completed_by_id[iid] = cached
            resumed_ids.add(iid)
            print(f"[Resume] Skipping cached instance: {iid}")
        else:
            pending_instances.append(inst)

    print("=== [Batch] Pre-Batch Modal Billing Check ===")
    breaker.check("pre-batch")

    if breaker.tripped:
        print(f"[CircuitBreaker] HALTED before batch start: {breaker.reason}", file=sys.stderr)
        return _write_batch_artifacts(
            batch_dir=batch_dir,
            batch_name=batch_name,
            profile=profile,
            model=model,
            selected_instances=selected_instances,
            completed_by_id=completed_by_id,
            resumed_ids=resumed_ids,
            elapsed_sec=time.time() - t_start,
            billing_state=breaker.to_dict(),
        )

    if pending_instances and app is None and executor is None and inst_executor is execute_instance:
        modal = _import_modal()
        app = modal.App.lookup("dalembert-swe-bench-batch", create_if_missing=True)

    checkpoint_lock = threading.Lock()
    dispatch_gate_lock = threading.Lock()

    # Write initial checkpoint state (reflecting any resumed instances)
    _write_batch_artifacts(
        batch_dir=batch_dir,
        batch_name=batch_name,
        profile=profile,
        model=model,
        selected_instances=selected_instances,
        completed_by_id=completed_by_id,
        resumed_ids=resumed_ids,
        elapsed_sec=time.time() - t_start,
        billing_state=breaker.to_dict(),
    )

    def _run_single(inst: dict[str, Any]) -> None:
        iid = str(inst["instance_id"])
        repo = eval_specs.infer_repo(inst)
        inst_dir = instances_root / iid

        with dispatch_gate_lock:
            if breaker.tripped:
                return
            breaker.check(f"pre-dispatch:{iid}")
            if breaker.tripped:
                print(
                    f"[CircuitBreaker] HALTING before dispatch of {iid}: {breaker.reason}",
                    file=sys.stderr,
                )
                return

        inst_dir.mkdir(parents=True, exist_ok=True)
        t_inst = time.time()
        try:
            result = inst_executor(
                inst,
                app=app,
                enginedge_bin=enginedge_bin,
                ws_url=ws_url,
                auth_token=auth_token,
                profile=profile,
                model=model,
                max_turns=max_turns,
                agent_timeout=agent_timeout,
                sandbox_timeout=sandbox_timeout,
                run_dir=inst_dir,
            )
        except Exception as exc:
            elapsed_inst = round(time.time() - t_inst, 2)
            print(f"[Error:{iid}] Instance execution failed: {exc}", file=sys.stderr)
            result = {
                "instance_id": iid,
                "repo": repo,
                "image": "",
                "profile": profile,
                "model": model,
                "model_name_or_path": f"dalembert-swe_bench-{model}",
                "model_patch": "",
                "max_turns": max_turns,
                "solver_rc": -1,
                "solver_elapsed_sec": elapsed_inst,
                "eval_elapsed_sec": 0.0,
                "audit": audit_logs("", ""),
                "patch_bytes": 0,
                "eval_cmd": eval_specs.build_eval_command(
                    repo,
                    str(inst.get("test_patch") or ""),
                    fail_to_pass=inst.get("FAIL_TO_PASS"),
                    pass_to_pass=inst.get("PASS_TO_PASS"),
                ),
                "eval_summary": {
                    "evaluated": False,
                    "exit_code": None,
                    "runner_exit_zero": False,
                    "test_directives": [],
                    "fail_to_pass": None,
                    "pass_to_pass": None,
                    "resolved": False,
                },
                "resolved": False,
                "error": str(exc),
            }

        patch_text = str(result.get("model_patch") or "")
        patch_path = inst_dir / "model.patch"
        if not patch_path.is_file():
            patch_path.write_text(patch_text, encoding="utf-8")
        for log_name in ("enginedge_stdout.log", "enginedge_stderr.log"):
            log_file = inst_dir / log_name
            if not log_file.is_file():
                log_file.write_text("", encoding="utf-8")

        summary_to_save = dict(result)
        summary_to_save.setdefault("instance_id", iid)
        summary_to_save.setdefault("repo", repo)
        summary_to_save.setdefault("patch_bytes", len(patch_text))

        with checkpoint_lock:
            (inst_dir / "summary.json").write_text(
                json.dumps(summary_to_save, indent=2, ensure_ascii=False),
                encoding="utf-8",
            )
            completed_by_id[iid] = summary_to_save
            _write_batch_artifacts(
                batch_dir=batch_dir,
                batch_name=batch_name,
                profile=profile,
                model=model,
                selected_instances=selected_instances,
                completed_by_id=completed_by_id,
                resumed_ids=resumed_ids,
                elapsed_sec=time.time() - t_start,
                billing_state=breaker.to_dict(),
            )

    if pending_instances:
        if effective_concurrency == 1:
            for inst in pending_instances:
                if breaker.tripped:
                    break
                _run_single(inst)
        else:
            with concurrent.futures.ThreadPoolExecutor(
                max_workers=effective_concurrency
            ) as pool:
                futures = [pool.submit(_run_single, inst) for inst in pending_instances]
                for fut in concurrent.futures.as_completed(futures):
                    fut.result()

    print("=== [Batch] Post-Batch Modal Billing Check ===")
    breaker.check("post-batch")

    return _write_batch_artifacts(
        batch_dir=batch_dir,
        batch_name=batch_name,
        profile=profile,
        model=model,
        selected_instances=selected_instances,
        completed_by_id=completed_by_id,
        resumed_ids=resumed_ids,
        elapsed_sec=time.time() - t_start,
        billing_state=breaker.to_dict(),
    )


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Dalembert x EnginEdge Multi-Repository Modal SWE-bench Batch Runner"
    )
    parser.add_argument(
        "--batch-name",
        default=None,
        help="Batch directory name under benchmarks/swe_bench/runs/batches/<batch_name>",
    )
    parser.add_argument(
        "--output-dir",
        default=None,
        help="Explicit output directory override (defaults to runs/batches/<batch_name>)",
    )
    parser.add_argument(
        "--instances",
        default=None,
        help="Comma-separated instance IDs or @path/to/instances.txt",
    )
    parser.add_argument(
        "--repo",
        default=None,
        help="Comma-separated repository filter (e.g. django/django,pytest-dev/pytest)",
    )
    parser.add_argument(
        "--stratified",
        action="store_true",
        help="Round-robin deterministic stratified sampling across repositories",
    )
    parser.add_argument(
        "--seed",
        type=int,
        default=42,
        help="Random seed for --stratified sampling (default: 42)",
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=10,
        help="Maximum number of instances to select (default: 10)",
    )
    parser.add_argument(
        "--concurrency",
        type=int,
        default=1,
        help="Concurrent Modal Sandboxes, hard-clamped to 1..3 (default: 1)",
    )
    parser.add_argument(
        "--resume",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Skip already-completed instances in batch_dir (default: --resume)",
    )
    parser.add_argument(
        "--retry-errors",
        action="store_true",
        default=False,
        help="When --resume is active, re-run instances with error or solver_rc != 0",
    )
    parser.add_argument(
        "--max-budget-usd",
        type=float,
        default=5.0,
        help="Maximum metered spend delta in USD before tripping circuit breaker (default: 5.0)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        default=False,
        help="Preview selected instances, images, eval commands, and resume status without Modal",
    )
    parser.add_argument("--profile", default="default")
    parser.add_argument("--model", default="hy4")
    parser.add_argument("--max-turns", type=int, default=45)
    parser.add_argument("--agent-timeout", type=int, default=540)
    parser.add_argument("--sandbox-timeout", type=int, default=600)
    parser.add_argument("--ws-url", default=os.environ.get("DALEMBERT_WS_URL", DEFAULT_WS_URL))
    parser.add_argument("--enginedge-bin", default=DEFAULT_ENGINEDGE_BIN)
    parser.add_argument("--modal-bin", default=DEFAULT_MODAL_BIN)
    parser.add_argument(
        "--parquet-path",
        "--dataset",
        dest="parquet_path",
        default=DEFAULT_PARQUET_PATH,
        help="Path to SWE-bench .parquet or local .json/.jsonl fixture",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_arg_parser()
    args = parser.parse_args(argv)

    batch_name = args.batch_name or dt.datetime.now().strftime("batch_%Y%m%d_%H%M%S")
    if args.output_dir:
        batch_dir = Path(args.output_dir)
    else:
        batch_dir = Path(__file__).resolve().parent / "runs" / "batches" / batch_name

    dataset = load_swebench_dataset(Path(args.parquet_path))
    selected = select_instances(
        dataset,
        instances=args.instances,
        repos=args.repo,
        stratified=args.stratified,
        seed=args.seed,
        limit=args.limit,
    )

    if args.dry_run:
        clamp_concurrency(args.concurrency)
        preview = render_dry_run_table(
            selected,
            batch_dir=batch_dir,
            resume=args.resume,
            retry_errors=args.retry_errors,
        )
        print(preview)
        return 0

    if not Path(args.enginedge_bin).is_file():
        print(f"ERROR: EnginEdge binary not found at {args.enginedge_bin}", file=sys.stderr)
        return 1

    auth_token = os.environ.get("HUB_AUTH_TOKEN", "")
    summary = run_batch(
        selected,
        batch_dir=batch_dir,
        batch_name=batch_name,
        profile=args.profile,
        model=args.model,
        max_turns=args.max_turns,
        agent_timeout=args.agent_timeout,
        sandbox_timeout=args.sandbox_timeout,
        concurrency=args.concurrency,
        resume=args.resume,
        retry_errors=args.retry_errors,
        max_budget_usd=args.max_budget_usd,
        ws_url=args.ws_url,
        auth_token=auth_token,
        enginedge_bin=args.enginedge_bin,
        modal_bin=args.modal_bin,
    )

    print("\n=== BATCH SUMMARY ===")
    print(
        f"Batch: {summary['batch_name']} | Completed: {summary['completed_count']}/{summary['selected_count']} "
        f"| Resolved: {summary['resolved_count']} (Pass@1={summary['pass_at_1'] * 100:.1f}%) "
        f"| CircuitBreaker: {'TRIPPED' if summary['billing']['tripped'] else 'OK'}"
    )
    print(f"Report written to: {batch_dir / 'REPORT.md'}")

    if summary["billing"]["tripped"]:
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
