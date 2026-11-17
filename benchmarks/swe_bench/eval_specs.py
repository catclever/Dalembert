"""
Multi-repository evaluation specifications and output graders for SWE-bench Verified.

Supports all 12 SWE-bench_Verified Python repositories using stdlib-only logic.
"""

from __future__ import annotations

import re
from pathlib import PurePosixPath
from typing import Any

SUPPORTED_REPOS: tuple[str, ...] = (
    "django/django",
    "sympy/sympy",
    "sphinx-doc/sphinx",
    "matplotlib/matplotlib",
    "scikit-learn/scikit-learn",
    "astropy/astropy",
    "pydata/xarray",
    "pytest-dev/pytest",
    "pylint-dev/pylint",
    "psf/requests",
    "mwaskom/seaborn",
    "pallets/flask",
)

NON_TEST_ASSET_EXTENSIONS: frozenset[str] = frozenset(
    {
        ".txt",
        ".json",
        ".rst",
        ".md",
        ".po",
        ".mo",
        ".cfg",
        ".ini",
        ".toml",
        ".yml",
        ".yaml",
        ".html",
        ".xml",
        ".sql",
        ".csv",
        ".png",
        ".jpg",
        ".jpeg",
        ".svg",
        ".gif",
        ".pdf",
        ".pkl",
        ".npy",
        ".npz",
        ".fits",
        ".dat",
    }
)

_ANSI_ESCAPE_RE = re.compile(r"\x1b\[[0-9;]*[a-zA-Z]")
_DIFF_HEADER_RE = re.compile(r"^diff --git a/(\S+) b/(\S+)\s*$")
_DJANGO_ENTRY_RE = re.compile(r"^\s*(?:(\w+)\s+)?\(([a-zA-Z0-9_]+(?:\.[a-zA-Z0-9_]+)+)\)")
_DJANGO_TEST_HEADER_RE = re.compile(r"^(\w+)\s+\(([a-zA-Z0-9_]+(?:\.[a-zA-Z0-9_]+)+)\)(.*)$")
_DJANGO_STATUS_RE = re.compile(
    r"\.\.\.\s*(ok|expected failure|FAIL|ERROR|unexpected success|skipped(?:\s+.*)?)\s*$"
)
_DJANGO_TRACEBACK_HEADER_RE = re.compile(
    r"^(FAIL|ERROR):\s+(\w+)\s+\(([a-zA-Z0-9_]+(?:\.[a-zA-Z0-9_]+)+)\)"
)
_SYMPY_FILE_HEADER_RE = re.compile(r"^([a-zA-Z0-9_./-]+\.py)\[\d+\]")
_SYMPY_VERBOSE_LINE_RE = re.compile(r"^\s*(test_[a-zA-Z0-9_]+)\s+(ok|f|F|E|s)\s*$")
_PYTEST_SUMMARY_LINE_RE = re.compile(r"^(PASSED|FAILED|ERROR|XFAIL|SKIPPED)\s+(.+?)\s*$")
_PYTEST_VERBOSE_LINE_RE = re.compile(
    r"^(.+?::.+?)\s+(PASSED|FAILED|ERROR|XFAIL|SKIPPED)(?:\s+\[\s*\d+%\])?\s*$"
)


def strip_ansi(text: str) -> str:
    """Remove ANSI terminal escape sequences from output strings."""
    return _ANSI_ESCAPE_RE.sub("", text)


def infer_repo_from_instance_id(instance_id: str) -> str:
    """Infer `<owner>/<repo>` from an instance ID like `scikit-learn__scikit-learn-1234`."""
    raw = instance_id.strip()
    if "/" in raw and "__" not in raw:
        return raw
    if "__" in raw:
        owner, rest = raw.split("__", 1)
        repo_name = re.sub(r"-\d+$", "", rest)
        return f"{owner}/{repo_name}"
    return raw


def infer_repo(instance_or_id: dict[str, Any] | str) -> str:
    """Resolve repository slug from an instance dictionary or instance_id string."""
    if isinstance(instance_or_id, str):
        return infer_repo_from_instance_id(instance_or_id)
    repo = str(instance_or_id.get("repo") or "").strip()
    if repo:
        return repo
    return infer_repo_from_instance_id(str(instance_or_id.get("instance_id") or ""))


def _extract_modified_py_files(test_patch: str) -> list[str]:
    """Extract non-deleted `.py` target paths from unified git diff headers."""
    if not test_patch:
        return []

    paths: list[str] = []
    lines = test_patch.splitlines()
    idx = 0
    total = len(lines)

    while idx < total:
        m = _DIFF_HEADER_RE.match(lines[idx])
        if not m:
            idx += 1
            continue

        b_path = m.group(2)
        is_deleted = b_path in ("dev/null", "/dev/null")
        idx += 1

        while idx < total and not lines[idx].startswith("diff --git "):
            hline = lines[idx]
            if hline.startswith("@@"):
                break
            if hline.startswith("deleted file mode") or hline.startswith("+++ /dev/null"):
                is_deleted = True
            idx += 1

        if is_deleted:
            continue

        clean_path = re.sub(r"^(?:\./|/)+", "", b_path)
        suffix = PurePosixPath(clean_path).suffix.lower()
        if suffix in NON_TEST_ASSET_EXTENSIONS or suffix != ".py":
            continue

        if clean_path not in paths:
            paths.append(clean_path)

    return paths


def _extract_django_module_from_test_id(entry: str) -> str | None:
    """
    Extract Django test module dotted path from a unittest identifier.

    Supports both:
      - `test_foo (auth_tests.test_validators.UsernameValidatorsTests)`
      - `test_foo (auth_tests.test_validators.UsernameValidatorsTests.test_foo)` (Python 3.11+)
    """
    m = _DJANGO_ENTRY_RE.search(entry)
    if not m:
        return None

    method_prefix = m.group(1)
    qual_path = m.group(2)
    parts = qual_path.split(".")
    if len(parts) < 2:
        return parts[0] if parts else None

    # Strip trailing test method name when formatted by Python 3.11+ unittest
    if len(parts) >= 3 and (
        (method_prefix and parts[-1] == method_prefix)
        or (parts[-1].startswith("test_") and parts[-2][:1].isupper())
    ):
        parts.pop()

    # Strip TestCase class segment(s)
    if len(parts) >= 2:
        if parts[-1][:1].isupper():
            while len(parts) > 1 and parts[-1][:1].isupper():
                parts.pop()
        else:
            parts.pop()

    mod_path = ".".join(parts)
    if mod_path.startswith("tests."):
        mod_path = mod_path[len("tests.") :]
    return mod_path or None


def extract_test_directives(
    repo: str,
    test_patch: str,
    fail_to_pass: list[str] | None = None,
    pass_to_pass: list[str] | None = None,
) -> list[str]:
    """
    Extract repository-appropriate test runner directives from `test_patch` with fallback
    to `fail_to_pass` + `pass_to_pass` test identifiers.
    """
    normalized_repo = infer_repo_from_instance_id(repo)
    py_paths = _extract_modified_py_files(test_patch)
    fallback_ids = list(fail_to_pass or []) + list(pass_to_pass or [])

    if normalized_repo == "django/django":
        directives: list[str] = []
        for rel_path in py_paths:
            if not rel_path.startswith("tests/"):
                continue
            trimmed = rel_path[len("tests/") : -3]  # strip "tests/" and ".py"
            dotted = trimmed.replace("/", ".")
            if dotted == "__init__":
                continue
            if dotted.endswith(".__init__"):
                dotted = dotted[: -len(".__init__")]
            if dotted and dotted not in directives:
                directives.append(dotted)

        if not directives:
            for item in fallback_ids:
                mod_path = _extract_django_module_from_test_id(item)
                if mod_path and mod_path not in directives:
                    directives.append(mod_path)
        return directives

    directives = list(py_paths)
    if not directives:
        for item in fallback_ids:
            candidate = re.sub(r"^(?:\./)+", "", item.split("::", 1)[0].strip())
            suffix = PurePosixPath(candidate).suffix.lower()
            if suffix == ".py" and suffix not in NON_TEST_ASSET_EXTENSIONS:
                if candidate not in directives:
                    directives.append(candidate)
    return directives


def build_eval_command(
    repo: str,
    test_patch: str,
    fail_to_pass: list[str] | None = None,
    pass_to_pass: list[str] | None = None,
    version: str | None = None,
) -> str:
    """Build the container evaluation command for any of the 12 SWE-bench_Verified repos."""
    _ = version  # reserved for future version-specific flags while keeping uniform signature
    normalized_repo = infer_repo_from_instance_id(repo)
    directives = extract_test_directives(
        normalized_repo,
        test_patch,
        fail_to_pass=fail_to_pass,
        pass_to_pass=pass_to_pass,
    )
    args_suffix = f" {' '.join(directives)}" if directives else ""

    if normalized_repo == "django/django":
        return (
            "/opt/miniconda3/envs/testbed/bin/python ./tests/runtests.py "
            f"--verbosity 2 --settings=test_sqlite --parallel 1{args_suffix}"
        )
    if normalized_repo == "sympy/sympy":
        return (
            "PYTHONWARNINGS='ignore::UserWarning,ignore::SyntaxWarning' "
            f"/opt/miniconda3/envs/testbed/bin/python bin/test -C --verbose{args_suffix}"
        )
    if normalized_repo == "sphinx-doc/sphinx":
        return f"/opt/miniconda3/envs/testbed/bin/tox --current-env -epy39 -v -- -rA{args_suffix}"

    return f"/opt/miniconda3/envs/testbed/bin/pytest -rA --tb=short -p no:cacheprovider{args_suffix}"


def _canonical_django_ids(func_name: str, qual_name: str) -> tuple[str, str]:
    """Return `(short_id, py311_id)` for a Django unittest method and qualified class/method."""
    if qual_name.endswith(f".{func_name}"):
        cls_qual = qual_name[: -(len(func_name) + 1)]
    else:
        cls_qual = qual_name
    short_id = f"{func_name} ({cls_qual})"
    py311_id = f"{func_name} ({cls_qual}.{func_name})"
    return short_id, py311_id


def _normalize_django_expected_id(test_id: str) -> str:
    m = _DJANGO_ENTRY_RE.match(test_id.strip())
    if not m or not m.group(1):
        return test_id.strip()
    short_id, _ = _canonical_django_ids(m.group(1), m.group(2))
    return short_id


def _map_django_raw_status(raw_status: str) -> str:
    low = raw_status.strip().lower()
    if low in ("ok", "expected failure"):
        return "PASSED"
    if low.startswith("skipped"):
        return "SKIPPED"
    return "FAILED"


def _record_status(status_map: dict[str, str], key: str, new_status: str) -> None:
    """Record test status ensuring `FAILED` is never overwritten by `PASSED` or `SKIPPED`."""
    prev = status_map.get(key)
    if prev == "FAILED":
        return
    if prev == "PASSED" and new_status == "SKIPPED":
        return
    status_map[key] = new_status


def _parse_django_status_map(output: str) -> dict[str, str]:
    status_map: dict[str, str] = {}
    lines = output.splitlines()
    total = len(lines)

    for idx, line in enumerate(lines):
        tb_match = _DJANGO_TRACEBACK_HEADER_RE.match(line)
        if tb_match:
            short_id, py311_id = _canonical_django_ids(tb_match.group(2), tb_match.group(3))
            _record_status(status_map, short_id, "FAILED")
            _record_status(status_map, py311_id, "FAILED")
            continue

        hdr_match = _DJANGO_TEST_HEADER_RE.match(line)
        if not hdr_match:
            continue

        func_name, qual_name, tail = hdr_match.group(1), hdr_match.group(2), hdr_match.group(3)
        short_id, py311_id = _canonical_django_ids(func_name, qual_name)

        matched_status: str | None = None
        inline_status = _DJANGO_STATUS_RE.search(tail)
        if inline_status:
            matched_status = _map_django_raw_status(inline_status.group(1))
        else:
            upper_bound = min(total, idx + 13)  # scan up to 12 subsequent lines
            for look_idx in range(idx + 1, upper_bound):
                next_line = lines[look_idx]
                if (
                    _DJANGO_TEST_HEADER_RE.match(next_line)
                    or _DJANGO_TRACEBACK_HEADER_RE.match(next_line)
                    or next_line.startswith("-" * 50)
                    or next_line.startswith("=" * 50)
                ):
                    break
                st_match = _DJANGO_STATUS_RE.search(next_line)
                if st_match:
                    candidate_status = _map_django_raw_status(st_match.group(1))
                    if candidate_status == "FAILED":
                        matched_status = "FAILED"
                        break
                    matched_status = candidate_status
                    if not next_line.startswith((" ", "\t")) or "..." in next_line:
                        break

        if matched_status is not None:
            _record_status(status_map, short_id, matched_status)
            _record_status(status_map, py311_id, matched_status)

    return status_map


def _strip_pytest_reason(rest: str) -> str:
    """
    Split ` - <reason>` suffix from a `pytest -rA` summary target without corrupting
    parametrized `[a-b]` or `[a - b]` node IDs.
    """
    bracket_depth = 0
    escaped = False
    length = len(rest)

    for idx, ch in enumerate(rest):
        if escaped:
            escaped = False
            continue
        if ch == "\\":
            escaped = True
            continue
        if ch == "[":
            bracket_depth += 1
        elif ch == "]" and bracket_depth > 0:
            bracket_depth -= 1
        elif bracket_depth == 0 and rest[idx : idx + 3] == " - ":
            return rest[:idx].strip()
            # Unreachable after return; loop terminates on first top-level " - "
    _ = length
    return rest.strip()


def _normalize_nodeid(nodeid: str) -> str:
    return re.sub(r"^(?:\./)+", "", nodeid.strip())


def _map_pytest_raw_status(raw_status: str) -> str:
    if raw_status in ("PASSED", "XFAIL"):
        return "PASSED"
    if raw_status == "SKIPPED":
        return "SKIPPED"
    return "FAILED"


def _parse_pytest_status_map(output: str) -> dict[str, str]:
    status_map: dict[str, str] = {}

    for line in output.splitlines():
        stripped = line.strip()
        if not stripped:
            continue

        sum_match = _PYTEST_SUMMARY_LINE_RE.match(stripped)
        if sum_match:
            raw_status, raw_rest = sum_match.group(1), sum_match.group(2)
            nodeid = (
                raw_rest.strip()
                if raw_status == "PASSED"
                else _strip_pytest_reason(raw_rest)
            )
            if "::" in nodeid or nodeid.endswith(".py"):
                mapped = _map_pytest_raw_status(raw_status)
                _record_status(status_map, nodeid, mapped)
                _record_status(status_map, _normalize_nodeid(nodeid), mapped)
                continue

        verb_match = _PYTEST_VERBOSE_LINE_RE.match(stripped)
        if verb_match:
            nodeid = verb_match.group(1).strip()
            raw_status = verb_match.group(2)
            mapped = _map_pytest_raw_status(raw_status)
            _record_status(status_map, nodeid, mapped)
            _record_status(status_map, _normalize_nodeid(nodeid), mapped)

    return status_map


def _lookup_pytest_status(status_map: dict[str, str], expected_id: str) -> str | None:
    if expected_id in status_map:
        return status_map[expected_id]

    norm_expected = _normalize_nodeid(expected_id)
    if norm_expected in status_map:
        return status_map[norm_expected]

    # Normalized suffix match if leading path prefix differs
    for recorded_id, status in status_map.items():
        norm_recorded = _normalize_nodeid(recorded_id)
        if norm_recorded.endswith("/" + norm_expected) or norm_expected.endswith(
            "/" + norm_recorded
        ):
            return status

    # Collection-level ERROR on the containing test file
    if "::" in norm_expected:
        file_part = norm_expected.split("::", 1)[0]
        if status_map.get(file_part) == "FAILED":
            return "FAILED"

    return None


def _parse_sympy_status_map(output: str) -> dict[str, str]:
    status_map: dict[str, str] = {}
    current_file: str | None = None

    for line in output.splitlines():
        stripped = line.strip()
        if not stripped:
            continue

        file_match = _SYMPY_FILE_HEADER_RE.match(stripped)
        if file_match:
            current_file = _normalize_nodeid(file_match.group(1))

        sym_match = _SYMPY_VERBOSE_LINE_RE.match(line)
        if sym_match:
            func_name, code = sym_match.group(1), sym_match.group(2)
            if code in ("ok", "f"):
                mapped = "PASSED"
            elif code in ("F", "E"):
                mapped = "FAILED"
            else:
                mapped = "SKIPPED"
            _record_status(status_map, func_name, mapped)
            if current_file:
                _record_status(status_map, f"{current_file}::{func_name}", mapped)

    # Merge pytest -rA / verbose fallback lines if pytest was used
    pytest_map = _parse_pytest_status_map(output)
    for nodeid, mapped in pytest_map.items():
        _record_status(status_map, nodeid, mapped)
        if "::" in nodeid:
            func_part = nodeid.rsplit("::", 1)[-1]
            _record_status(status_map, func_part, mapped)

    return status_map


def _bucket_expected_tests(
    repo: str,
    status_map: dict[str, str],
    expected_tests: list[str],
) -> tuple[list[str], list[str], list[str]]:
    passed: list[str] = []
    failed: list[str] = []
    missing: list[str] = []

    for test_id in expected_tests:
        if repo == "django/django":
            status = status_map.get(test_id.strip()) or status_map.get(
                _normalize_django_expected_id(test_id)
            )
        elif repo == "sympy/sympy":
            status = _lookup_pytest_status(status_map, test_id)
            if status is None and "::" in test_id:
                status = status_map.get(test_id.rsplit("::", 1)[-1])
        else:
            status = _lookup_pytest_status(status_map, test_id)

        if status == "PASSED":
            passed.append(test_id)
        elif status == "FAILED":
            failed.append(test_id)
        else:
            missing.append(test_id)

    return passed, failed, missing


def grade_eval_output(
    repo: str,
    output: str,
    fail_to_pass: list[str],
    pass_to_pass: list[str],
    exit_code: int,
    test_directives: list[str] | None = None,
) -> dict[str, Any]:
    """Grade test runner output against `fail_to_pass` and `pass_to_pass` expectations."""
    normalized_repo = infer_repo_from_instance_id(repo)
    clean_output = strip_ansi(output or "")

    if normalized_repo == "django/django":
        status_map = _parse_django_status_map(clean_output)
    elif normalized_repo == "sympy/sympy":
        status_map = _parse_sympy_status_map(clean_output)
    else:
        status_map = _parse_pytest_status_map(clean_output)

    f2p_passed, f2p_failed, f2p_missing = _bucket_expected_tests(
        normalized_repo, status_map, fail_to_pass
    )
    p2p_passed, p2p_failed, p2p_missing = _bucket_expected_tests(
        normalized_repo, status_map, pass_to_pass
    )

    resolved = bool(
        len(fail_to_pass) > 0
        and len(f2p_passed) == len(fail_to_pass)
        and len(p2p_passed) == len(pass_to_pass)
        and not f2p_failed
        and not p2p_failed
        and not f2p_missing
        and not p2p_missing
    )

    return {
        "evaluated": True,
        "exit_code": exit_code,
        "runner_exit_zero": exit_code == 0,
        "test_directives": list(test_directives or []),
        "fail_to_pass": {
            "total": len(fail_to_pass),
            "passed": len(f2p_passed),
            "failed": f2p_failed,
            "missing": f2p_missing,
        },
        "pass_to_pass": {
            "total": len(pass_to_pass),
            "passed": len(p2p_passed),
            "failed": p2p_failed,
            "missing": p2p_missing,
        },
        "resolved": resolved,
    }
