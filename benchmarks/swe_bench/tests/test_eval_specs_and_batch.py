"""
Comprehensive stdlib `unittest` suite for `eval_specs`, `modal_canary`, and `modal_batch`.

Runs cleanly on Python 3 stdlib without installing `modal` or `pyarrow`.
"""

from __future__ import annotations

import contextlib
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any
from unittest import mock

_REPO_ROOT = str(Path(__file__).resolve().parents[3])
if _REPO_ROOT not in sys.path:
    sys.path.insert(0, _REPO_ROOT)

try:
    from benchmarks.swe_bench import eval_specs, modal_batch, modal_canary
except ImportError:
    _SWE_DIR = str(Path(__file__).resolve().parents[1])
    if _SWE_DIR not in sys.path:
        sys.path.insert(0, _SWE_DIR)
    import eval_specs  # type: ignore[no-redef]
    import modal_batch  # type: ignore[no-redef]
    import modal_canary  # type: ignore[no-redef]


class EvalSpecsDirectivesAndCommandTests(unittest.TestCase):
    def test_supported_repos_contains_all_12_swebench_verified_repos(self) -> None:
        expected = {
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
        }
        self.assertEqual(len(eval_specs.SUPPORTED_REPOS), 12)
        self.assertEqual(set(eval_specs.SUPPORTED_REPOS), expected)

    def test_infer_repo_handles_hyphenated_instance_ids_and_explicit_repo(self) -> None:
        self.assertEqual(
            eval_specs.infer_repo({"instance_id": "scikit-learn__scikit-learn-13496"}),
            "scikit-learn/scikit-learn",
        )
        self.assertEqual(
            eval_specs.infer_repo("sphinx-doc__sphinx-8595"),
            "sphinx-doc/sphinx",
        )
        self.assertEqual(
            eval_specs.infer_repo("pytest-dev__pytest-7432"),
            "pytest-dev/pytest",
        )
        self.assertEqual(
            eval_specs.infer_repo(
                {"repo": "pydata/xarray", "instance_id": "custom_id_without_sep"}
            ),
            "pydata/xarray",
        )

    def test_django_directives_from_patch_and_asset_deletion_filtering(self) -> None:
        test_patch = "\n".join(
            [
                "diff --git a/tests/auth_tests/test_validators.py b/tests/auth_tests/test_validators.py",
                "index 1111111..2222222 100644",
                "--- a/tests/auth_tests/test_validators.py",
                "+++ b/tests/auth_tests/test_validators.py",
                "@@ -1,3 +1,4 @@",
                "diff --git a/tests/model_fields/tests.py b/tests/model_fields/tests.py",
                "--- a/tests/model_fields/tests.py",
                "+++ b/tests/model_fields/tests.py",
                "@@ -10,2 +10,5 @@",
                "diff --git a/tests/i18n/__init__.py b/tests/i18n/__init__.py",
                "--- a/tests/i18n/__init__.py",
                "+++ b/tests/i18n/__init__.py",
                "@@ -1,2 +1,3 @@",
                "diff --git a/tests/old_removed.py b/tests/old_removed.py",
                "deleted file mode 100644",
                "--- a/tests/old_removed.py",
                "+++ /dev/null",
                "diff --git a/tests/auth_tests/data/fixture.json b/tests/auth_tests/data/fixture.json",
                "--- a/tests/auth_tests/data/fixture.json",
                "+++ b/tests/auth_tests/data/fixture.json",
                "@@ -1 +1 @@",
                "diff --git a/django/contrib/auth/validators.py b/django/contrib/auth/validators.py",
                "--- a/django/contrib/auth/validators.py",
                "+++ b/django/contrib/auth/validators.py",
                "@@ -1 +1 @@",
            ]
        )
        directives = eval_specs.extract_test_directives("django/django", test_patch)
        self.assertEqual(
            directives,
            ["auth_tests.test_validators", "model_fields.tests", "i18n"],
        )
        cmd = eval_specs.build_eval_command("django/django", test_patch)
        self.assertEqual(
            cmd,
            "/opt/miniconda3/envs/testbed/bin/python ./tests/runtests.py "
            "--verbosity 2 --settings=test_sqlite --parallel 1 "
            "auth_tests.test_validators model_fields.tests i18n",
        )

    def test_django_directives_fallback_supports_py310_and_py311_method_ids(self) -> None:
        f2p = [
            "test_ascii_validator (auth_tests.test_validators.UsernameValidatorsTests)",
            "test_slug_field (model_fields.tests.SlugFieldTests.test_slug_field)",
        ]
        p2p = [
            "test_unicode_validator (auth_tests.test_validators.UsernameValidatorsTests.test_unicode_validator)",
        ]
        directives = eval_specs.extract_test_directives(
            "django/django", "", fail_to_pass=f2p, pass_to_pass=p2p
        )
        self.assertEqual(directives, ["auth_tests.test_validators", "model_fields.tests"])

    def test_sympy_and_sphinx_commands_and_asset_filtering(self) -> None:
        sympy_patch = (
            "diff --git a/sympy/core/tests/test_arit.py b/sympy/core/tests/test_arit.py\n"
            "--- a/sympy/core/tests/test_arit.py\n"
            "+++ b/sympy/core/tests/test_arit.py\n"
            "@@ -1,2 +1,3 @@\n"
        )
        self.assertEqual(
            eval_specs.build_eval_command("sympy/sympy", sympy_patch),
            "PYTHONWARNINGS='ignore::UserWarning,ignore::SyntaxWarning' "
            "/opt/miniconda3/envs/testbed/bin/python bin/test -C --verbose "
            "sympy/core/tests/test_arit.py",
        )

        sphinx_patch = (
            "diff --git a/tests/roots/test-root/index.rst b/tests/roots/test-root/index.rst\n"
            "--- a/tests/roots/test-root/index.rst\n"
            "+++ b/tests/roots/test-root/index.rst\n"
            "@@ -1 +1,2 @@\n"
            "diff --git a/tests/test_build_html.py b/tests/test_build_html.py\n"
            "--- a/tests/test_build_html.py\n"
            "+++ b/tests/test_build_html.py\n"
            "@@ -10,3 +10,6 @@\n"
        )
        self.assertEqual(
            eval_specs.build_eval_command("sphinx-doc/sphinx", sphinx_patch),
            "/opt/miniconda3/envs/testbed/bin/tox --current-env -epy39 -v -- -rA "
            "tests/test_build_html.py",
        )

    def test_all_nine_pytest_repos_build_compatible_pytest_command_and_fallback(self) -> None:
        pytest_repos = [
            ("matplotlib/matplotlib", "lib/matplotlib/tests/test_axes.py"),
            ("scikit-learn/scikit-learn", "sklearn/metrics/tests/test_classification.py"),
            ("astropy/astropy", "astropy/io/fits/tests/test_hdulist.py"),
            ("pydata/xarray", "xarray/tests/test_dataset.py"),
            ("pytest-dev/pytest", "testing/test_collection.py"),
            ("pylint-dev/pylint", "tests/checkers/unittest_variables.py"),
            ("psf/requests", "tests/test_requests.py"),
            ("mwaskom/seaborn", "tests/test_categorical.py"),
            ("pallets/flask", "tests/test_basic.py"),
        ]
        asset_only_patch = (
            "diff --git a/data/sample.fits b/data/sample.fits\n"
            "--- a/data/sample.fits\n"
            "+++ b/data/sample.fits\n"
            "@@ -1 +1 @@\n"
            "diff --git a/data/matrix.npz b/data/matrix.npz\n"
            "--- a/data/matrix.npz\n"
            "+++ b/data/matrix.npz\n"
            "@@ -1 +1 @@\n"
        )
        for repo, test_file in pytest_repos:
            cmd = eval_specs.build_eval_command(
                repo,
                asset_only_patch,
                fail_to_pass=[f"{test_file}::test_bug_fix[case1]"],
                pass_to_pass=[f"{test_file}::test_regression"],
            )
            self.assertNotIn("--no-header", cmd)
            self.assertEqual(
                cmd,
                f"/opt/miniconda3/envs/testbed/bin/pytest -rA --tb=short -p no:cacheprovider {test_file}",
            )


class EvalSpecsGradingTests(unittest.TestCase):
    def test_grade_django_single_line_multiline_docstring_py311_and_expected_failure(self) -> None:
        django_output = "\n".join(
            [
                "Creating test database for alias 'default'...",
                "test_ascii_validator (auth_tests.test_validators.UsernameValidatorsTests) ... ok",
                "test_multiline_doc (auth_tests.test_validators.UsernameValidatorsTests)",
                "Verify that validator handles edge cases (like trailing newline)",
                "across a four-line docstring description",
                "without confusing the parser",
                "on line four ... ok",
                "test_py311_style (auth_tests.test_validators.UsernameValidatorsTests.test_py311_style) ... ok",
                "test_known_xfail (auth_tests.test_validators.UsernameValidatorsTests) ... expected failure",
                "----------------------------------------------------------------------",
                "Ran 4 tests in 0.012s",
                "OK (expected failures=1)",
            ]
        )
        res = eval_specs.grade_eval_output(
            repo="django/django",
            output=django_output,
            fail_to_pass=[
                "test_ascii_validator (auth_tests.test_validators.UsernameValidatorsTests)",
                "test_multiline_doc (auth_tests.test_validators.UsernameValidatorsTests)",
                "test_py311_style (auth_tests.test_validators.UsernameValidatorsTests)",
            ],
            pass_to_pass=[
                "test_known_xfail (auth_tests.test_validators.UsernameValidatorsTests)",
            ],
            exit_code=0,
            test_directives=["auth_tests.test_validators"],
        )
        self.assertTrue(res["resolved"])
        self.assertTrue(res["runner_exit_zero"])
        self.assertEqual(res["fail_to_pass"]["passed"], 3)
        self.assertEqual(res["pass_to_pass"]["passed"], 1)
        self.assertEqual(res["fail_to_pass"]["failed"], [])
        self.assertEqual(res["fail_to_pass"]["missing"], [])

    def test_grade_django_detects_failures_and_missing_or_skipped_tests(self) -> None:
        django_output = "\n".join(
            [
                "test_good (app.tests.SampleTests) ... ok",
                "test_broken (app.tests.SampleTests) ... FAIL",
                "test_skipped_one (app.tests.SampleTests) ... skipped 'SQLite unsupported'",
            ]
        )
        res = eval_specs.grade_eval_output(
            repo="django/django",
            output=django_output,
            fail_to_pass=[
                "test_broken (app.tests.SampleTests)",
                "test_not_ran (app.tests.SampleTests)",
            ],
            pass_to_pass=[
                "test_good (app.tests.SampleTests)",
                "test_skipped_one (app.tests.SampleTests)",
            ],
            exit_code=1,
        )
        self.assertFalse(res["resolved"])
        self.assertFalse(res["runner_exit_zero"])
        self.assertEqual(res["fail_to_pass"]["failed"], ["test_broken (app.tests.SampleTests)"])
        self.assertEqual(res["fail_to_pass"]["missing"], ["test_not_ran (app.tests.SampleTests)"])
        self.assertEqual(
            res["pass_to_pass"]["missing"], ["test_skipped_one (app.tests.SampleTests)"]
        )

    def test_grade_sympy_verbose_runner_and_pytest_fallback(self) -> None:
        sympy_verbose = "\n".join(
            [
                "============================= test process starts ==============================",
                "sympy/core/tests/test_arit.py[5]",
                "test_add_mul ok",
                "test_known_issue f",
                "test_div_zero F",
                "test_boom E",
                "test_optional s",
            ]
        )
        res_fail = eval_specs.grade_eval_output(
            repo="sympy/sympy",
            output=sympy_verbose,
            fail_to_pass=["test_add_mul", "test_div_zero"],
            pass_to_pass=["test_known_issue", "test_optional"],
            exit_code=1,
        )
        self.assertFalse(res_fail["resolved"])
        self.assertEqual(res_fail["fail_to_pass"]["passed"], 1)
        self.assertEqual(res_fail["fail_to_pass"]["failed"], ["test_div_zero"])
        self.assertEqual(res_fail["pass_to_pass"]["passed"], 1)
        self.assertEqual(res_fail["pass_to_pass"]["missing"], ["test_optional"])

        sympy_pass = "\n".join(
            [
                "sympy/core/tests/test_arit.py[2]",
                "test_add_mul ok",
                "test_known_issue f",
            ]
        )
        res_ok = eval_specs.grade_eval_output(
            repo="sympy/sympy",
            output=sympy_pass,
            fail_to_pass=["test_add_mul"],
            pass_to_pass=["test_known_issue"],
            exit_code=0,
        )
        self.assertTrue(res_ok["resolved"])

        sympy_pytest_out = "\n".join(
            [
                "=========================== short test summary info ============================",
                "PASSED sympy/core/tests/test_arit.py::test_add_mul",
                "PASSED sympy/core/tests/test_arit.py::test_known_issue",
            ]
        )
        res_pytest = eval_specs.grade_eval_output(
            repo="sympy/sympy",
            output=sympy_pytest_out,
            fail_to_pass=["test_add_mul"],
            pass_to_pass=["sympy/core/tests/test_arit.py::test_known_issue"],
            exit_code=0,
        )
        self.assertTrue(res_pytest["resolved"])

    def test_grade_pytest_handles_parametrized_brackets_reasons_and_errors(self) -> None:
        pytest_out = "\n".join(
            [
                "=========================== short test summary info ============================",
                "PASSED ./tests/test_calc.py::test_op[param-1-param-2]",
                "PASSED tests/test_calc.py::test_spaces[10 - 3]",
                "FAILED tests/test_calc.py::test_bad[a - b] - AssertionError: expected a - b == 0",
                "ERROR tests/test_calc.py::test_fixture_boom[x-y] - RuntimeError: setup failed - bad env",
            ]
        )
        graded_fail = eval_specs.grade_eval_output(
            repo="pytest-dev/pytest",
            output=pytest_out,
            fail_to_pass=[
                "tests/test_calc.py::test_op[param-1-param-2]",
                "tests/test_calc.py::test_bad[a - b]",
            ],
            pass_to_pass=[
                "tests/test_calc.py::test_spaces[10 - 3]",
                "tests/test_calc.py::test_fixture_boom[x-y]",
            ],
            exit_code=1,
        )
        self.assertFalse(graded_fail["resolved"])
        self.assertEqual(graded_fail["fail_to_pass"]["passed"], 1)
        self.assertEqual(
            graded_fail["fail_to_pass"]["failed"], ["tests/test_calc.py::test_bad[a - b]"]
        )
        self.assertEqual(graded_fail["pass_to_pass"]["passed"], 1)
        self.assertEqual(
            graded_fail["pass_to_pass"]["failed"],
            ["tests/test_calc.py::test_fixture_boom[x-y]"],
        )

        # Verbose-only fallback when -rA summary block is absent
        verbose_only = "\n".join(
            [
                "tests/test_requests.py::test_PreparedRequest[param-1-param-2] PASSED [ 50%]",
                "tests/test_requests.py::test_redirect PASSED [100%]",
            ]
        )
        graded_pass = eval_specs.grade_eval_output(
            repo="psf/requests",
            output=verbose_only,
            fail_to_pass=["tests/test_requests.py::test_PreparedRequest[param-1-param-2]"],
            pass_to_pass=["tests/test_requests.py::test_redirect"],
            exit_code=0,
        )
        self.assertTrue(graded_pass["resolved"])


class BillingAndCircuitBreakerTests(unittest.TestCase):
    def test_parse_billing_summary_handles_ansi_dollar_signs_and_credits(self) -> None:
        ansi_text = (
            "\x1b[1mModal Billing Summary\x1b[0m\n"
            "\x1b[36mMetered Cost:\x1b[0m    $0.42\n"
            "Credits:        -$0.42\n"
            "\x1b[32mBilled Cost:\x1b[0m     $0.00\n"
        )
        parsed = modal_batch.parse_billing_summary(ansi_text)
        self.assertAlmostEqual(parsed["metered_cost"], 0.42)
        self.assertAlmostEqual(parsed["credits"], -0.42)
        self.assertAlmostEqual(parsed["billed_cost"], 0.0)

        no_dollar_text = (
            "Metered Cost:    1.25\n"
            "Credits:        -1.25\n"
            "Billed Cost:     0.00\n"
        )
        parsed_plain = modal_batch.parse_billing_summary(no_dollar_text)
        self.assertAlmostEqual(parsed_plain["metered_cost"], 1.25)
        self.assertAlmostEqual(parsed_plain["credits"], -1.25)
        self.assertAlmostEqual(parsed_plain["billed_cost"], 0.0)

        with self.assertRaises(ValueError):
            modal_batch.parse_billing_summary("Unrelated CLI output without billing fields")

    def test_circuit_breaker_stays_closed_within_starter_credits_and_budget(self) -> None:
        snapshots = iter(
            [
                "Metered Cost: $10.00\nCredits: -$10.00\nBilled Cost: $0.00",
                "Metered Cost: $12.50\nCredits: -$12.50\nBilled Cost: $0.00",
            ]
        )
        breaker = modal_batch.BillingCircuitBreaker(
            max_budget_usd=5.0, billing_fetcher=lambda: next(snapshots)
        )
        breaker.check("pre-batch")
        self.assertFalse(breaker.tripped)
        state = breaker.check("post-batch")
        self.assertFalse(state["tripped"])
        self.assertAlmostEqual(state["metered_delta_usd"], 2.50)

    def test_circuit_breaker_trips_on_nonzero_billed_cost(self) -> None:
        snapshots = iter(
            [
                "Metered Cost: $10.00\nCredits: -$10.00\nBilled Cost: $0.00",
                "Metered Cost: $10.20\nCredits: -$10.00\nBilled Cost: $0.20",
            ]
        )
        breaker = modal_batch.BillingCircuitBreaker(
            max_budget_usd=5.0, billing_fetcher=lambda: next(snapshots)
        )
        breaker.check("pre-batch")
        self.assertFalse(breaker.tripped)
        breaker.check("pre-dispatch:inst-2")
        self.assertTrue(breaker.tripped)
        self.assertIn("Billed Cost", breaker.reason or "")

    def test_circuit_breaker_trips_when_metered_delta_reaches_max_budget(self) -> None:
        snapshots = iter(
            [
                "Metered Cost: $2.00\nCredits: -$2.00\nBilled Cost: $0.00",
                "Metered Cost: $7.00\nCredits: -$7.00\nBilled Cost: $0.00",
            ]
        )
        breaker = modal_batch.BillingCircuitBreaker(
            max_budget_usd=5.0, billing_fetcher=lambda: next(snapshots)
        )
        breaker.check("pre-batch")
        breaker.check("pre-dispatch:inst-3")
        self.assertTrue(breaker.tripped)
        self.assertAlmostEqual(breaker.metered_delta_usd, 5.0)
        self.assertIn("Metered spend delta", breaker.reason or "")


class BatchSamplingDryRunAndExecutionTests(unittest.TestCase):
    def _build_12_repo_dataset(self, per_repo: int = 2) -> list[dict[str, Any]]:
        rows: list[dict[str, Any]] = []
        for repo in eval_specs.SUPPORTED_REPOS:
            slug_prefix = repo.replace("/", "__")
            for i in range(1, per_repo + 1):
                iid = f"{slug_prefix}-{1000 + i}"
                if repo == "django/django":
                    test_patch = (
                        f"diff --git a/tests/app_{i}/tests.py b/tests/app_{i}/tests.py\n"
                        f"--- a/tests/app_{i}/tests.py\n"
                        f"+++ b/tests/app_{i}/tests.py\n"
                        "@@ -1 +1,2 @@\n"
                    )
                    f2p = [f"test_fix_{i} (app_{i}.tests.FixTests)"]
                else:
                    test_patch = (
                        f"diff --git a/tests/test_mod_{i}.py b/tests/test_mod_{i}.py\n"
                        f"--- a/tests/test_mod_{i}.py\n"
                        f"+++ b/tests/test_mod_{i}.py\n"
                        "@@ -1 +1,2 @@\n"
                    )
                    f2p = [f"tests/test_mod_{i}.py::test_fix_{i}"]
                rows.append(
                    {
                        "instance_id": iid,
                        "repo": repo,
                        "base_commit": "deadbeef1234",
                        "problem_statement": f"Fix issue in {iid}",
                        "test_patch": test_patch,
                        "FAIL_TO_PASS": json.dumps(f2p),
                        "PASS_TO_PASS": json.dumps([]),
                    }
                )
        return rows

    def test_clamp_concurrency_enforces_1_to_3_bounds(self) -> None:
        buf = io.StringIO()
        with contextlib.redirect_stderr(buf):
            self.assertEqual(modal_batch.clamp_concurrency(0), 1)
            self.assertEqual(modal_batch.clamp_concurrency(-2), 1)
            self.assertEqual(modal_batch.clamp_concurrency(2), 2)
            self.assertEqual(modal_batch.clamp_concurrency(8), 3)
        self.assertIn("clamping to 1", buf.getvalue())
        self.assertIn("clamping to 3", buf.getvalue())

    def test_stratified_selection_covers_all_12_repos_deterministically(self) -> None:
        dataset = self._build_12_repo_dataset(per_repo=3)
        pick_a = modal_batch.select_instances(
            dataset, stratified=True, seed=42, limit=12
        )
        pick_b = modal_batch.select_instances(
            list(reversed(dataset)), stratified=True, seed=42, limit=12
        )
        self.assertEqual([r["instance_id"] for r in pick_a], [r["instance_id"] for r in pick_b])
        self.assertEqual(len(pick_a), 12)
        self.assertEqual({r["repo"] for r in pick_a}, set(eval_specs.SUPPORTED_REPOS))

    def test_instance_file_and_repo_filters(self) -> None:
        dataset = self._build_12_repo_dataset(per_repo=2)
        with tempfile.TemporaryDirectory() as tmp:
            ids_file = Path(tmp) / "ids.txt"
            ids_file.write_text(
                "# comment line\n"
                "sympy__sympy-1002\n"
                "django__django-1001, pytest-dev__pytest-1001\n",
                encoding="utf-8",
            )
            filtered = modal_batch.select_instances(
                dataset,
                instances=f"@{ids_file}",
                repos="django/django,sympy/sympy",
                limit=10,
            )
            self.assertEqual(
                [r["instance_id"] for r in filtered],
                ["sympy__sympy-1002", "django__django-1001"],
            )

    def test_dry_run_cli_on_jsonl_fixture_succeeds_without_modal_or_enginedge(self) -> None:
        dataset = self._build_12_repo_dataset(per_repo=1)
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            fixture_path = tmp_path / "fixture.jsonl"
            fixture_path.write_text(
                "\n".join(json.dumps(r) for r in dataset) + "\n", encoding="utf-8"
            )
            batch_out = tmp_path / "batch_preview"

            stdout_buf = io.StringIO()
            with contextlib.redirect_stdout(stdout_buf):
                rc = modal_batch.main(
                    [
                        "--parquet-path",
                        str(fixture_path),
                        "--output-dir",
                        str(batch_out),
                        "--stratified",
                        "--seed",
                        "42",
                        "--limit",
                        "4",
                        "--dry-run",
                        "--enginedge-bin",
                        str(tmp_path / "missing_enginedge_binary"),
                    ]
                )

            self.assertEqual(rc, 0)
            out_text = stdout_buf.getvalue()
            for col in ("instance_id", "repo", "primary_image", "eval_cmd", "resume_status"):
                self.assertIn(col, out_text)
            self.assertFalse(batch_out.exists())

    def test_batch_loop_resume_retry_errors_and_artifacts(self) -> None:
        dataset = self._build_12_repo_dataset(per_repo=1)[:3]
        calls: list[str] = []

        def fake_executor(instance: dict[str, Any], **kwargs: Any) -> dict[str, Any]:
            iid = instance["instance_id"]
            calls.append(iid)
            if iid == dataset[1]["instance_id"] and calls.count(iid) == 1:
                raise RuntimeError("transient network glitch")
            is_resolved = iid != dataset[2]["instance_id"]
            return {
                "instance_id": iid,
                "repo": instance["repo"],
                "image": f"ghcr.io/epoch-research/swe-bench.eval.x86_64.{iid}:latest",
                "profile": kwargs["profile"],
                "model": kwargs["model"],
                "model_name_or_path": f"dalembert-swe_bench-{kwargs['model']}",
                "model_patch": f"diff --git a/x.py b/x.py\n# patch for {iid}\n",
                "max_turns": kwargs["max_turns"],
                "solver_rc": 0,
                "solver_elapsed_sec": 12.5,
                "eval_elapsed_sec": 4.2,
                "audit": {
                    "phases_seen": ["locate", "reproduce", "patch_and_verify"],
                    "cloud_osint_hits": [],
                    "cloud_osint_count": 0,
                },
                "patch_bytes": 42,
                "eval_cmd": "pytest",
                "eval_summary": {
                    "evaluated": True,
                    "exit_code": 0 if is_resolved else 1,
                    "runner_exit_zero": is_resolved,
                    "test_directives": [],
                    "fail_to_pass": {"total": 1, "passed": 1 if is_resolved else 0, "failed": [], "missing": []},
                    "pass_to_pass": {"total": 0, "passed": 0, "failed": [], "missing": []},
                    "resolved": is_resolved,
                },
                "resolved": is_resolved,
                "error": None,
            }

        billing_ok = lambda: "Metered Cost: $0.50\nCredits: -$0.50\nBilled Cost: $0.00"

        with tempfile.TemporaryDirectory() as tmp:
            batch_dir = Path(tmp) / "batch_test_run"

            # Pass 1: runs all 3; instance[1] errors
            sum1 = modal_batch.run_batch(
                dataset,
                batch_dir=batch_dir,
                batch_name="batch_test_run",
                executor=fake_executor,
                billing_fetcher=billing_ok,
            )
            self.assertEqual(len(calls), 3)
            self.assertEqual(sum1["completed_count"], 3)
            self.assertEqual(sum1["resolved_count"], 1)
            self.assertEqual(sum1["error_count"], 1)

            # Pass 2: --resume without --retry-errors skips all 3 cached instances
            sum2 = modal_batch.run_batch(
                dataset,
                batch_dir=batch_dir,
                batch_name="batch_test_run",
                resume=True,
                retry_errors=False,
                executor=fake_executor,
                billing_fetcher=billing_ok,
            )
            self.assertEqual(len(calls), 3)  # zero new executions!
            self.assertEqual(sum2["resumed_count"], 3)
            self.assertEqual(sum2["executed_count"], 0)

            # Pass 3: --resume + --retry-errors re-runs ONLY instance[1], which now resolves!
            sum3 = modal_batch.run_batch(
                dataset,
                batch_dir=batch_dir,
                batch_name="batch_test_run",
                resume=True,
                retry_errors=True,
                executor=fake_executor,
                billing_fetcher=billing_ok,
            )
            self.assertEqual(calls, [d["instance_id"] for d in dataset] + [dataset[1]["instance_id"]])
            self.assertEqual(sum3["resumed_count"], 2)
            self.assertEqual(sum3["executed_count"], 1)
            self.assertEqual(sum3["resolved_count"], 2)
            self.assertEqual(sum3["error_count"], 0)
            self.assertAlmostEqual(sum3["pass_at_1"], round(2 / 3, 4))

            # Verify generated artifacts on disk
            pred_lines = (batch_dir / "predictions.jsonl").read_text(encoding="utf-8").splitlines()
            self.assertEqual(len(pred_lines), 3)
            pred_ids = [json.loads(line)["instance_id"] for line in pred_lines]
            self.assertEqual(pred_ids, [d["instance_id"] for d in dataset])

            saved_summary = json.loads((batch_dir / "batch_summary.json").read_text(encoding="utf-8"))
            self.assertEqual(saved_summary["resolved_count"], 2)
            self.assertEqual(saved_summary["phase_stats"]["full_3_phase_count"], 3)

            report_md = (batch_dir / "REPORT.md").read_text(encoding="utf-8")
            self.assertIn("## Summary Metrics", report_md)
            self.assertIn("## Billing Guardrail Status", report_md)
            self.assertIn("## Per-Repository Pass@1", report_md)
            self.assertIn("## Per-Instance Results", report_md)

    def test_batch_circuit_breaker_halts_mid_batch_when_budget_exceeded(self) -> None:
        dataset = self._build_12_repo_dataset(per_repo=1)[:3]
        dispatched: list[str] = []

        # Billing sequence:
        # 1. pre-batch: $1.00
        # 2. pre-dispatch inst[0]: $1.00 -> runs inst[0]
        # 3. pre-dispatch inst[1]: $3.60 (delta $2.60 >= max_budget $2.50) -> TRIPS!
        # 4. post-batch: $3.60
        billing_snapshots = iter(
            [
                "Metered Cost: $1.00\nCredits: -$1.00\nBilled Cost: $0.00",
                "Metered Cost: $1.00\nCredits: -$1.00\nBilled Cost: $0.00",
                "Metered Cost: $3.60\nCredits: -$3.60\nBilled Cost: $0.00",
                "Metered Cost: $3.60\nCredits: -$3.60\nBilled Cost: $0.00",
            ]
        )

        def fake_executor(instance: dict[str, Any], **kwargs: Any) -> dict[str, Any]:
            iid = instance["instance_id"]
            dispatched.append(iid)
            return {
                "instance_id": iid,
                "repo": instance["repo"],
                "model_patch": "diff --git a/a.py b/a.py\n",
                "solver_rc": 0,
                "solver_elapsed_sec": 5.0,
                "audit": {"phases_seen": ["locate"], "cloud_osint_hits": [], "cloud_osint_count": 0},
                "eval_summary": {"evaluated": True, "resolved": True},
                "resolved": True,
                "error": None,
            }

        with tempfile.TemporaryDirectory() as tmp:
            batch_dir = Path(tmp) / "cb_halt_batch"
            summary = modal_batch.run_batch(
                dataset,
                batch_dir=batch_dir,
                batch_name="cb_halt_batch",
                max_budget_usd=2.50,
                executor=fake_executor,
                billing_fetcher=lambda: next(billing_snapshots),
            )
            self.assertEqual(dispatched, [dataset[0]["instance_id"]])
            self.assertTrue(summary["billing"]["tripped"])
            self.assertEqual(summary["completed_count"], 1)
            self.assertEqual(summary["halted_count"], 2)
            report_md = (batch_dir / "REPORT.md").read_text(encoding="utf-8")
            self.assertIn("**TRIPPED**", report_md)


class ModalCanaryMultiRepoExecutionTests(unittest.TestCase):
    def _make_fake_proc(self, stdout: str = "", stderr: str = "", rc: int = 0) -> Any:
        proc = mock.MagicMock()
        proc.stdout = io.StringIO(stdout)
        proc.stderr = io.StringIO(stderr)
        proc.returncode = rc
        proc.wait.return_value = rc
        return proc

    def test_execute_instance_runs_pytest_repo_and_terminates_both_sandboxes(self) -> None:
        solver_sb = mock.MagicMock()
        solver_sb.exec.side_effect = [
            # 1. enginedge --version
            self._make_fake_proc("enginedge 0.4.0\n", "", 0),
            # 2. write_remote_b64_file(/tmp/problem_statement.txt)
            self._make_fake_proc("", "", 0),
            # 3. solve_script
            self._make_fake_proc(
                "Phase 1/3 [:locate]\nPhase 2/3 [:reproduce]\nPhase 3/3 [:patch_and_verify]\n",
                "",
                0,
            ),
            # 4. git diff
            self._make_fake_proc("diff --git a/requests/models.py b/requests/models.py\n+fix\n", "", 0),
            # 5. git status --short
            self._make_fake_proc(" M requests/models.py\n", "", 0),
        ]

        eval_sb = mock.MagicMock()
        eval_sb.exec.side_effect = [
            # 1. write_remote_b64_file(/tmp/model.patch)
            self._make_fake_proc("", "", 0),
            # 2. write_remote_b64_file(/tmp/test.patch)
            self._make_fake_proc("", "", 0),
            # 3. eval_script
            self._make_fake_proc(
                "=========================== short test summary info ============================\n"
                "PASSED tests/test_requests.py::test_fix_case[a-b]\n"
                "PASSED tests/test_requests.py::test_existing\n",
                "",
                0,
            ),
        ]

        fake_modal = mock.MagicMock()
        fake_modal.Sandbox.create.return_value = eval_sb

        instance = {
            "instance_id": "psf__requests-2148",
            "base_commit": "abcdef123456",
            "problem_statement": "Handle socket error cleanly",
            "test_patch": (
                "diff --git a/tests/test_requests.py b/tests/test_requests.py\n"
                "--- a/tests/test_requests.py\n"
                "+++ b/tests/test_requests.py\n"
                "@@ -1 +1,2 @@\n"
            ),
            "FAIL_TO_PASS": ["tests/test_requests.py::test_fix_case[a-b]"],
            "PASS_TO_PASS": ["tests/test_requests.py::test_existing"],
        }

        with tempfile.TemporaryDirectory() as tmp:
            run_dir = Path(tmp) / "psf__requests-2148"
            with (
                mock.patch.object(modal_canary, "_import_modal", return_value=fake_modal),
                mock.patch.object(
                    modal_canary,
                    "create_solver_sandbox",
                    return_value=(solver_sb, "ghcr.io/epoch-research/swe-bench.eval.x86_64.psf__requests-2148:latest", mock.MagicMock()),
                ),
            ):
                res = modal_canary.execute_instance(
                    instance,
                    app=mock.MagicMock(),
                    enginedge_bin="/bin/true",
                    ws_url="wss://example.invalid",
                    auth_token="secret",
                    profile="default",
                    model="hy4",
                    max_turns=45,
                    agent_timeout=540,
                    sandbox_timeout=600,
                    run_dir=run_dir,
                )

            solver_sb.terminate.assert_called_once()
            eval_sb.terminate.assert_called_once()
            self.assertEqual(res["repo"], "psf/requests")
            self.assertTrue(res["resolved"])
            self.assertEqual(res["audit"]["phases_seen"], ["locate", "reproduce", "patch_and_verify"])
            self.assertEqual(res["audit"]["cloud_osint_count"], 0)
            self.assertTrue((run_dir / "model.patch").is_file())
            self.assertTrue((run_dir / "eval_output.log").is_file())


if __name__ == "__main__":
    unittest.main()
