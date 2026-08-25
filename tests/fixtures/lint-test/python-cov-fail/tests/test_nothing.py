"""A test that passes without touching lib/add.py.

The point of this fixture is the COVERAGE gate. Before 2026-08-25 it had no
tests at all, so pytest exited 5 ("no tests collected") and the nightly
assertion went green on a failure that had nothing to do with coverage — the
gate itself was never exercised, which is how the bare `--cov` bug survived.
"""


def test_the_suite_runs():
    assert True
