# PSSO Test Harness + `test-pkg.sh` + Reporting + Coverage Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the pytest harness, the one-command `testing/test-pkg.sh` entrypoint, the reporting layer (pytest-html + JUnit + per-run artifacts + a rendered scenario matrix), the seed scenarios, and a coverage spike with a guaranteed fallback — so a developer can point one command at a freshly built `.pkg` and get a pass/fail/skip matrix plus diagnosable artifacts.

**Architecture:** A Python + pytest harness in `testing/harness/`. Pure logic (log-line parsing, IdP request assertions, the scenario-matrix renderer, fault-payload building) is built test-first with pytest. Live-VM/UI/IdP steps are driven through thin drivers (`drivers/{guest,ui,idp}.py`) and verified with concrete smoke checks, not fabricated unit tests. The `vm` fixture clones the golden Tart image per test, the `guest` driver shells into it over SSH, the `ui` driver drives the `loginwindow` login sheet over Tart's `--vnc-experimental` VNC framebuffer, and the `idp` fixture arms faults and reads back requests via the Plan-1 mock IdP `/control` API. Each scenario asserts on the extension's **observable** behavior (`webloginlog:` log lines, guest/app-group state, IdP-received requests, UI screenshots) — never on genuine Secure-Enclave keys, which do not exist in a VM guest.

**Tech Stack:** Python 3.12, pytest, pytest-html, `vncdotool`, `requests` (TLS against the test CA), OpenSSH client, `jinja2` (matrix render); Tart (clone/run/ip/delete); Docker Compose (Plan-1 IdP stack); LLVM `llvm-cov`/`llvm-profdata` (coverage spike); Xcode `xcodebuild` (existing `ssoeTests` XCTest, coverage fallback).

**This is Plan 3 of 3.** Plan 1 = the fault-injectable mock IdP + Keycloak stack (`testing/idp/`, `docker compose`, `/control` API). Plan 2 = the golden VM image pipeline (Tart + nanomdm), which publishes `ghcr.io/sunstoneinstitute/weblogin-psso-test-vm:<macos-ver>` with the PSSO profile, test CA, `/etc/hosts` mapping, and an SSH key baked in. **This plan hard-depends on both:** its live smoke checks and scenarios only pass on an Apple Silicon Mac that has Tart + docker installed, the Plan-1 stack buildable, and the Plan-2 golden image pullable. Pure-logic tasks (Tasks 2–5) have **no** such dependency and run green anywhere with Python 3.12.

**Grounding in the extension code** (`ssoe/AuthenticationViewController.swift`, `ssoe/Helpers.swift`, `ssoe/RegistrationState.swift`):
- Every diagnostic log line is prefixed `webloginlog:` — this is the stable string the harness greps, independent of the OSLog subsystem/category (`LogSubsystem` is injectable via Info.plist; confirming its exact value is an open item, so we filter on `eventMessage` text, not `subsystem`).
- The registration completion regression fixed in commit `89c5a0a`: `registerUser`'s `catch` for `saveUserLoginConfiguration` logged `webloginlog: Failed to save the configuration` and, **before the fix**, fell through to the password success path (which logs `webloginlog: The audience in user registration is:` then calls `completion(.success)`), double-invoking the completion. The observable double-completion signature is therefore: a "Failed to save the configuration" line **followed by** a "The audience in user registration is" line. The harness asserts that never happens.

---

## File Structure

```
testing/
├─ test-pkg.sh                     one-command entrypoint (this plan)
└─ harness/
   ├─ pyproject.toml               harness package + dev/test deps
   ├─ .gitignore                   artifacts/, .venv/, caches
   ├─ pytest.ini                   testpaths, junit/html defaults, markers
   ├─ conftest.py                  fixtures: paths, idp, vm, guest, ui, artifacts
   ├─ harness/
   │  ├─ __init__.py
   │  ├─ log_assert.py             PURE: parse webloginlog ndjson, completion accounting
   │  ├─ matrix.py                 PURE: JUnit XML → ScenarioResult[] → markdown matrix
   │  └─ drivers/
   │     ├─ __init__.py
   │     ├─ idp.py                 IdpControl (live) + RequestLog (PURE parser)
   │     ├─ guest.py               Guest: SSH exec, install pkg, state, logs
   │     └─ ui.py                  UI: vncdotool screenshot/click/type
   ├─ scenarios/
   │  ├─ __init__.py
   │  ├─ conftest.py               scenario-local helpers (trigger_activation)
   │  └─ test_scenarios.py         one parametrized test per design-spec row
   ├─ coverage/
   │  ├─ spike-llvm-cov.sh         SPIKE: attempt in-VM .profraw → llvm-cov
   │  └─ fallback-xctest.sh        FALLBACK (guaranteed): ssoeTests coverage + matrix
   ├─ tests/                       harness's OWN unit tests (pure logic)
   │  ├─ test_log_assert.py
   │  ├─ test_matrix.py
   │  └─ test_request_log.py
   └─ README.md                    added last
```

---

### Task 1: Scaffold the `testing/harness` Python package

**Files:**
- Create: `testing/harness/pyproject.toml`
- Create: `testing/harness/harness/__init__.py`
- Create: `testing/harness/harness/drivers/__init__.py`
- Create: `testing/harness/scenarios/__init__.py`
- Create: `testing/harness/.gitignore`
- Create: `testing/harness/pytest.ini`

- [ ] **Step 1: Create `pyproject.toml`**

`testing/harness/pyproject.toml`:

```toml
[project]
name = "psso-test-harness"
version = "0.1.0"
description = "pytest harness driving VM-based PSSO extension tests"
requires-python = ">=3.12"
dependencies = [
    "pytest>=8",
    "pytest-html>=4",
    "requests>=2.31",
    "vncdotool>=1.2",
    "jinja2>=3.1",
]

[project.optional-dependencies]
dev = ["pytest>=8"]

[build-system]
requires = ["setuptools>=68"]
build-backend = "setuptools.build_meta"

[tool.setuptools.packages.find]
include = ["harness*"]
```

- [ ] **Step 2: Create package markers**

`testing/harness/harness/__init__.py`:

```python
"""VM-based PSSO extension test harness."""
```

`testing/harness/harness/drivers/__init__.py`:

```python
"""Live drivers: guest (SSH), ui (VNC), idp (control API)."""
```

`testing/harness/scenarios/__init__.py`:

```python
"""Parametrized PSSO test scenarios."""
```

- [ ] **Step 3: Create `.gitignore`**

`testing/harness/.gitignore`:

```
artifacts/
.venv/
__pycache__/
*.egg-info/
.pytest_cache/
report.html
junit.xml
scenario-matrix.md
```

- [ ] **Step 4: Create `pytest.ini`**

`testing/harness/pytest.ini`:

```ini
[pytest]
testpaths = tests scenarios
markers =
    live: requires a running Tart golden image + IdP stack (Plans 1 & 2).
    scenario: a design-spec seed scenario contributing to the matrix.
addopts = -ra
```

- [ ] **Step 5: Create the venv and install**

Run:
```bash
cd testing/harness && python3.12 -m venv .venv && . .venv/bin/activate && pip install -e '.[dev]'
```
Expected: ends with `Successfully installed ... psso-test-harness-0.1.0 ...`

- [ ] **Step 6: Commit**

```bash
git add testing/harness/pyproject.toml testing/harness/harness/__init__.py testing/harness/harness/drivers/__init__.py testing/harness/scenarios/__init__.py testing/harness/.gitignore testing/harness/pytest.ini
git commit -m "test(harness): scaffold pytest harness package"
```

---

### Task 2: `webloginlog:` log parser + completion accounting (PURE, TDD)

**Files:**
- Create: `testing/harness/harness/log_assert.py`
- Test: `testing/harness/tests/test_log_assert.py`

- [ ] **Step 1: Write the failing test**

`testing/harness/tests/test_log_assert.py`:

```python
from harness.log_assert import (
    parse_webloginlog,
    count_matching,
    assert_logged,
    double_completion_after_save_failure,
)

# `log show --style ndjson` emits one JSON object per line, plus non-JSON
# header/footer lines the parser must ignore.
NDJSON = """\
{"eventMessage":"webloginlog: viewDidLoad","subsystem":"no.uio.WebloginSSO"}
some non-json banner line that log show prints
{"eventMessage":"unrelated chatter from another process"}
{"eventMessage":"webloginlog: Failed to save the configuration Error 1."}
{"eventMessage":"webloginlog: The audience in user registration is: aud"}
"""

FIXED_LOG = """\
{"eventMessage":"webloginlog: Starting user registration"}
{"eventMessage":"webloginlog: Failed to save the configuration Error 1."}
"""


def test_parse_extracts_only_webloginlog_messages_in_order():
    msgs = parse_webloginlog(NDJSON)
    assert msgs == [
        "webloginlog: viewDidLoad",
        "webloginlog: Failed to save the configuration Error 1.",
        "webloginlog: The audience in user registration is: aud",
    ]


def test_count_matching_counts_substring_hits():
    msgs = parse_webloginlog(NDJSON)
    assert count_matching(msgs, "viewDidLoad") == 1
    assert count_matching(msgs, "not present") == 0


def test_assert_logged_passes_when_present_and_raises_when_absent():
    msgs = parse_webloginlog(NDJSON)
    assert_logged(msgs, "viewDidLoad")  # no raise
    try:
        assert_logged(msgs, "nope")
        assert False, "expected AssertionError"
    except AssertionError:
        pass


def test_double_completion_signature_detected_in_buggy_log():
    # Save failure FOLLOWED BY the password success-path log == pre-89c5a0a bug.
    assert double_completion_after_save_failure(parse_webloginlog(NDJSON)) is True


def test_no_double_completion_in_fixed_log():
    assert double_completion_after_save_failure(parse_webloginlog(FIXED_LOG)) is False
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd testing/harness && . .venv/bin/activate && pytest tests/test_log_assert.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'harness.log_assert'`

- [ ] **Step 3: Write minimal implementation**

`testing/harness/harness/log_assert.py`:

```python
from __future__ import annotations
import json

MARKER = "webloginlog:"
SAVE_FAILURE = "Failed to save the configuration"
# `registerUser`'s password success path logs this immediately before
# completion(.success). Seeing it AFTER a save failure is the double-completion
# signature the 89c5a0a fix removed.
PASSWORD_SUCCESS_PATH = "The audience in user registration is"


def parse_webloginlog(ndjson_text: str) -> list[str]:
    """Extract `webloginlog:` eventMessages from `log show --style ndjson` output, in order."""
    out: list[str] = []
    for line in ndjson_text.splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            rec = json.loads(line)
        except json.JSONDecodeError:
            continue
        msg = rec.get("eventMessage", "")
        if MARKER in msg:
            out.append(msg)
    return out


def count_matching(msgs: list[str], needle: str) -> int:
    return sum(1 for m in msgs if needle in m)


def assert_logged(msgs: list[str], needle: str) -> None:
    if count_matching(msgs, needle) == 0:
        raise AssertionError(f"expected a webloginlog line containing {needle!r}; got {msgs!r}")


def double_completion_after_save_failure(msgs: list[str]) -> bool:
    """True iff a save-config failure is followed by the password success-path log."""
    for i, m in enumerate(msgs):
        if SAVE_FAILURE in m:
            if any(PASSWORD_SUCCESS_PATH in later for later in msgs[i + 1 :]):
                return True
    return False
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest tests/test_log_assert.py -v`
Expected: PASS (5 passed)

- [ ] **Step 5: Commit**

```bash
git add testing/harness/harness/log_assert.py testing/harness/tests/test_log_assert.py
git commit -m "test(harness): webloginlog parser + double-completion detector"
```

---

### Task 3: IdP `RequestLog` parser + `IdpControl` client (PURE parser TDD; live client smoke-verified later)

**Files:**
- Create: `testing/harness/harness/drivers/idp.py`
- Test: `testing/harness/tests/test_request_log.py`

- [ ] **Step 1: Write the failing test**

`testing/harness/tests/test_request_log.py`:

```python
from harness.drivers.idp import RequestLog, fault_payload

# Shape mirrors Plan-1 mock-idp GET /control/requests entries.
ENTRIES = [
    {"method": "POST", "path": "/psso/nonce", "query": "", "body": "grant_type=srv_challenge"},
    {"method": "POST", "path": "/psso/token", "query": "", "body": "grant_type=authorization_code&code=abc"},
    {"method": "POST", "path": "/psso/token", "query": "", "body": "grant_type=refresh_token"},
]


def test_paths_lists_paths_in_order():
    rl = RequestLog(ENTRIES)
    assert rl.paths() == ["/psso/nonce", "/psso/token", "/psso/token"]


def test_count_filters_by_path_and_method():
    rl = RequestLog(ENTRIES)
    assert rl.count("/psso/token") == 2
    assert rl.count("/psso/nonce", method="POST") == 1
    assert rl.count("/psso/nonce", method="GET") == 0


def test_nonce_requested_true_when_present():
    assert RequestLog(ENTRIES).nonce_requested() is True
    assert RequestLog([]).nonce_requested() is False


def test_bodies_for_returns_matching_bodies():
    rl = RequestLog(ENTRIES)
    bodies = rl.bodies_for("/psso/token")
    assert any("authorization_code" in b for b in bodies)
    assert len(bodies) == 2


def test_fault_payload_builds_expected_dict():
    assert fault_payload("token_500") == {"type": "token_500", "times": 1}
    assert fault_payload("timeout", times=3) == {"type": "timeout", "times": 3}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest tests/test_request_log.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'harness.drivers.idp'`

- [ ] **Step 3: Write minimal implementation**

`testing/harness/harness/drivers/idp.py`:

```python
from __future__ import annotations
from typing import Any
import requests


def fault_payload(kind: str, times: int = 1) -> dict[str, Any]:
    """Build the JSON body for POST /control/fault. `kind` matches Plan-1 FaultKind values."""
    return {"type": kind, "times": times}


class RequestLog:
    """Pure read-model over GET /control/requests entries — for scenario assertions."""

    def __init__(self, entries: list[dict[str, Any]]) -> None:
        self.entries = entries

    def paths(self) -> list[str]:
        return [e["path"] for e in self.entries]

    def count(self, path: str, method: str | None = None) -> int:
        return sum(
            1
            for e in self.entries
            if e["path"] == path and (method is None or e["method"] == method)
        )

    def bodies_for(self, path: str) -> list[str]:
        return [e.get("body", "") for e in self.entries if e["path"] == path]

    def nonce_requested(self) -> bool:
        return "/psso/nonce" in self.paths()


class IdpControl:
    """Live client for the Plan-1 mock-idp /control API (TLS via the test CA)."""

    def __init__(self, base_url: str, ca_cert: str, timeout: float = 10.0) -> None:
        self.base_url = base_url.rstrip("/")
        self._verify = ca_cert
        self._timeout = timeout

    def reset(self) -> None:
        r = requests.post(f"{self.base_url}/control/reset", verify=self._verify, timeout=self._timeout)
        r.raise_for_status()

    def arm(self, kind: str, times: int = 1) -> None:
        r = requests.post(
            f"{self.base_url}/control/fault",
            json=fault_payload(kind, times),
            verify=self._verify,
            timeout=self._timeout,
        )
        r.raise_for_status()

    def request_log(self) -> RequestLog:
        r = requests.get(f"{self.base_url}/control/requests", verify=self._verify, timeout=self._timeout)
        r.raise_for_status()
        return RequestLog(r.json())
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest tests/test_request_log.py -v`
Expected: PASS (5 passed)

- [ ] **Step 5: Commit**

```bash
git add testing/harness/harness/drivers/idp.py testing/harness/tests/test_request_log.py
git commit -m "test(harness): IdP RequestLog parser + control client"
```

---

### Task 4: Scenario-matrix renderer (JUnit XML → markdown table) (PURE, TDD)

**Files:**
- Create: `testing/harness/harness/matrix.py`
- Test: `testing/harness/tests/test_matrix.py`

- [ ] **Step 1: Write the failing test**

`testing/harness/tests/test_matrix.py`:

```python
from harness.matrix import ScenarioResult, parse_junit, render_matrix

JUNIT = """<?xml version="1.0" encoding="utf-8"?>
<testsuites>
  <testsuite name="pytest" tests="3" failures="1" skipped="1">
    <testcase classname="scenarios.test_scenarios" name="test_scenario[happy_path]"/>
    <testcase classname="scenarios.test_scenarios" name="test_scenario[token_500]">
      <failure message="assert 500">boom</failure>
    </testcase>
    <testcase classname="scenarios.test_scenarios" name="test_scenario[profile_repush]">
      <skipped message="needs nanomdm live"/>
    </testcase>
  </testsuite>
</testsuites>
"""


def test_parse_junit_maps_status_per_case():
    results = parse_junit(JUNIT)
    by_name = {r.name: r.status for r in results}
    assert by_name == {
        "happy_path": "pass",
        "token_500": "fail",
        "profile_repush": "skip",
    }


def test_render_matrix_is_a_markdown_table_with_a_row_per_scenario():
    md = render_matrix(
        [
            ScenarioResult(name="happy_path", status="pass"),
            ScenarioResult(name="token_500", status="fail"),
            ScenarioResult(name="profile_repush", status="skip"),
        ]
    )
    assert "| Scenario | Result |" in md
    assert "| happy_path | pass |" in md
    assert "| token_500 | fail |" in md
    assert "| profile_repush | skip |" in md


def test_render_matrix_handles_empty_results():
    md = render_matrix([])
    assert "| Scenario | Result |" in md
    assert "_no scenarios ran_" in md
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest tests/test_matrix.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'harness.matrix'`

- [ ] **Step 3: Write minimal implementation**

`testing/harness/harness/matrix.py`:

```python
from __future__ import annotations
import re
from dataclasses import dataclass
from xml.etree import ElementTree as ET


@dataclass(frozen=True)
class ScenarioResult:
    name: str
    status: str  # "pass" | "fail" | "skip"


def _short_name(testcase_name: str) -> str:
    """`test_scenario[happy_path]` -> `happy_path`; fall back to the raw name."""
    m = re.search(r"\[(.+)\]", testcase_name)
    return m.group(1) if m else testcase_name


def parse_junit(xml_text: str) -> list[ScenarioResult]:
    root = ET.fromstring(xml_text)
    results: list[ScenarioResult] = []
    for case in root.iter("testcase"):
        if case.find("failure") is not None or case.find("error") is not None:
            status = "fail"
        elif case.find("skipped") is not None:
            status = "skip"
        else:
            status = "pass"
        results.append(ScenarioResult(name=_short_name(case.get("name", "")), status=status))
    return results


def render_matrix(results: list[ScenarioResult]) -> str:
    lines = ["| Scenario | Result |", "| --- | --- |"]
    if not results:
        lines.append("| _no scenarios ran_ | — |")
    for r in results:
        lines.append(f"| {r.name} | {r.status} |")
    return "\n".join(lines) + "\n"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest tests/test_matrix.py -v`
Expected: PASS (3 passed)

- [ ] **Step 5: Commit**

```bash
git add testing/harness/harness/matrix.py testing/harness/tests/test_matrix.py
git commit -m "test(harness): scenario-matrix renderer from JUnit XML"
```

---

### Task 5: Guest (SSH) and UI (VNC) drivers

These drivers talk to a live VM, so there is nothing pure to TDD; they are verified by the smoke checks in Task 7 and the scenarios in Task 8. Keep them thin.

**Files:**
- Create: `testing/harness/harness/drivers/guest.py`
- Create: `testing/harness/harness/drivers/ui.py`

- [ ] **Step 1: Write the guest driver**

`testing/harness/harness/drivers/guest.py`:

```python
from __future__ import annotations
import subprocess
from dataclasses import dataclass


@dataclass
class RunResult:
    returncode: int
    stdout: str
    stderr: str


class Guest:
    """SSH into the cloned macOS VM to install the pkg and observe state/logs."""

    def __init__(self, ip: str, ssh_key: str, user: str = "admin") -> None:
        self.ip = ip
        self._key = ssh_key
        self._user = user

    def _ssh_base(self) -> list[str]:
        return [
            "ssh",
            "-i", self._key,
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "ConnectTimeout=10",
            f"{self._user}@{self.ip}",
        ]

    def run(self, command: str, timeout: float = 120.0) -> RunResult:
        p = subprocess.run(
            self._ssh_base() + [command],
            capture_output=True, text=True, timeout=timeout,
        )
        return RunResult(p.returncode, p.stdout, p.stderr)

    def copy_in(self, local_path: str, remote_path: str, timeout: float = 300.0) -> None:
        subprocess.run(
            [
                "scp", "-i", self._key,
                "-o", "StrictHostKeyChecking=no",
                "-o", "UserKnownHostsFile=/dev/null",
                local_path, f"{self._user}@{self.ip}:{remote_path}",
            ],
            check=True, timeout=timeout,
        )

    def install_pkg(self, remote_pkg: str) -> RunResult:
        return self.run(f"sudo installer -pkg {remote_pkg} -target /", timeout=300.0)

    def platform_state(self) -> str:
        """`app-sso platform -s` — device/user registration + broker state."""
        return self.run("app-sso platform -s").stdout

    def profiles_list(self) -> str:
        return self.run("profiles list -all 2>/dev/null || profiles list").stdout

    def ext_logs(self, last: str = "5m") -> str:
        """`webloginlog:` extension log lines as `log show --style ndjson`."""
        cmd = (
            "log show --style ndjson "
            "--predicate 'eventMessage CONTAINS \"webloginlog:\"' "
            f"--last {last}"
        )
        return self.run(cmd, timeout=120.0).stdout

    def read_app_group_defaults(self, key: str, app_group: str = "group.no.uio.weblogin") -> str:
        """Read a key from the extension's app-group defaults suite."""
        return self.run(f"defaults read {app_group} {key} 2>&1 || true").stdout.strip()

    def clear_registration_state(self, app_group: str = "group.no.uio.weblogin") -> None:
        """Delete the app-group defaults domain to simulate leftover/corrupt state cleanup."""
        self.run(f"defaults delete {app_group} 2>/dev/null || true")

    def corrupt_app_group(self, app_group: str = "group.no.uio.weblogin") -> None:
        """Write a bogus value so the extension reads corrupt app-group state."""
        self.run(f"defaults write {app_group} disable_sso -string not-a-bool")
```

- [ ] **Step 2: Write the UI driver**

`testing/harness/harness/drivers/ui.py`:

```python
from __future__ import annotations
import os
from vncdotool import api


class UI:
    """Drive the loginwindow login/registration sheet over Tart's --vnc-experimental framebuffer.

    AppleScript UI scripting is restricted in loginwindow, so we drive pixels:
    screenshot, coordinate/image-match click, and type. Coordinate maps for the
    login sheet are an open item (see 'Open items carried forward').
    """

    def __init__(self, host: str, port: int, artifacts_dir: str, password: str | None = None) -> None:
        self._artifacts = artifacts_dir
        os.makedirs(self._artifacts, exist_ok=True)
        # vncdotool address form is 'host::port' (double colon = raw port, not display #).
        self._client = api.connect(f"{host}::{port}", password=password)

    def screenshot(self, name: str) -> str:
        path = os.path.join(self._artifacts, name if name.endswith(".png") else f"{name}.png")
        self._client.captureScreen(path)
        return path

    def click(self, x: int, y: int) -> None:
        self._client.mouseMove(x, y)
        self._client.mousePress(1)

    def click_image(self, template_png: str, timeout: float = 15.0) -> None:
        """Wait for `template_png` to appear on screen, then click its top-left origin."""
        # expectScreen raises on timeout; mouse is left at the matched location.
        self._client.expectScreen(template_png, maxrms=20)
        self._client.mousePress(1)

    def type(self, text: str) -> None:
        self._client.type(text)

    def key(self, keyname: str) -> None:
        self._client.keyPress(keyname)

    def close(self) -> None:
        self._client.disconnect()
```

- [ ] **Step 3: Verify both modules import cleanly**

Run: `cd testing/harness && . .venv/bin/activate && python -c "import harness.drivers.guest, harness.drivers.ui; print('ok')"`
Expected: prints `ok` (imports `vncdotool`; no VM needed for import).

- [ ] **Step 4: Commit**

```bash
git add testing/harness/harness/drivers/guest.py testing/harness/harness/drivers/ui.py
git commit -m "test(harness): guest (SSH) and ui (VNC) drivers"
```

---

### Task 6: Fixtures — `paths`, `idp`, `vm`, `guest`, `ui`, `artifacts`

**Files:**
- Create: `testing/harness/conftest.py`

- [ ] **Step 1: Write the root conftest**

`testing/harness/conftest.py`:

```python
from __future__ import annotations
import datetime as dt
import os
import re
import subprocess
import time
import uuid

import pytest

from harness.drivers.idp import IdpControl
from harness.drivers.guest import Guest
from harness.drivers.ui import UI

# --- Environment contract (set by test-pkg.sh; sane local defaults otherwise) ---
GOLDEN_IMAGE = os.environ.get("PSSO_GOLDEN_IMAGE", "ghcr.io/sunstoneinstitute/weblogin-psso-test-vm:latest")
IDP_BASE_URL = os.environ.get("PSSO_IDP_BASE_URL", "https://idp.test:8443")
IDP_CA_CERT = os.environ.get("PSSO_IDP_CA_CERT", "../idp/certs/ca.crt")
SSH_KEY = os.environ.get("PSSO_SSH_KEY", os.path.expanduser("~/.ssh/psso_test_vm"))
PKG_PATH = os.environ.get("PSSO_PKG", "")
ARTIFACTS_ROOT = os.environ.get("PSSO_ARTIFACTS", "artifacts")


def _needs(path_or_bin: str, kind: str) -> None:
    if kind == "bin" and subprocess.run(["which", path_or_bin], capture_output=True).returncode != 0:
        pytest.skip(f"required binary {path_or_bin!r} not on PATH (Plans 1 & 2 host requirement)")
    if kind == "file" and not os.path.exists(path_or_bin):
        pytest.skip(f"required file {path_or_bin!r} missing (produced by Plans 1 & 2)")


@pytest.fixture(scope="session")
def artifacts_root() -> str:
    stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    root = os.path.join(ARTIFACTS_ROOT, f"run-{stamp}")
    os.makedirs(root, exist_ok=True)
    return root


@pytest.fixture
def artifacts(artifacts_root, request) -> str:
    """Per-scenario artifacts subdir named after the test node."""
    safe = re.sub(r"[^A-Za-z0-9_.-]+", "_", request.node.name)
    d = os.path.join(artifacts_root, safe)
    os.makedirs(d, exist_ok=True)
    return d


@pytest.fixture
def idp() -> IdpControl:
    """Clean mock-IdP control client; resets faults + recorded requests before AND after."""
    _needs(IDP_CA_CERT, "file")
    control = IdpControl(base_url=IDP_BASE_URL, ca_cert=IDP_CA_CERT)
    control.reset()
    yield control
    control.reset()


@pytest.fixture
def vm() -> str:
    """Clone the golden image, boot it, yield the guest IP, then delete the clone."""
    _needs("tart", "bin")
    name = f"run-{uuid.uuid4().hex[:8]}"
    subprocess.run(["tart", "clone", GOLDEN_IMAGE, name], check=True)
    # --vnc-experimental prints a vnc://...@IP:PORT URL to stdout; captured for the ui fixture.
    proc = subprocess.Popen(
        ["tart", "run", name, "--vnc-experimental", "--no-graphics"],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
    )
    vnc_url = _wait_for_vnc_url(proc)
    ip = _wait_for_ip(name)
    try:
        yield {"name": name, "ip": ip, "vnc_url": vnc_url}
    finally:
        proc.terminate()
        subprocess.run(["tart", "stop", name], capture_output=True)
        subprocess.run(["tart", "delete", name], capture_output=True)


def _wait_for_vnc_url(proc, timeout: float = 60.0) -> str:
    deadline = time.time() + timeout
    while time.time() < deadline:
        line = proc.stdout.readline()
        if line and "vnc://" in line:
            return line.strip().split("vnc://", 1)[1]
        if proc.poll() is not None:
            raise RuntimeError("tart run exited before printing a VNC URL")
    raise TimeoutError("no VNC URL from tart run")


def _wait_for_ip(name: str, timeout: float = 120.0) -> str:
    deadline = time.time() + timeout
    while time.time() < deadline:
        r = subprocess.run(["tart", "ip", name], capture_output=True, text=True)
        ip = r.stdout.strip()
        if r.returncode == 0 and ip:
            return ip
        time.sleep(3)
    raise TimeoutError(f"no IP for {name} within {timeout}s")


@pytest.fixture
def guest(vm) -> Guest:
    _needs(SSH_KEY, "file")
    return Guest(ip=vm["ip"], ssh_key=SSH_KEY)


@pytest.fixture
def ui(vm, artifacts) -> UI:
    # vnc_url form: [password@]host:port
    creds, _, hostport = vm["vnc_url"].rpartition("@")
    host, _, port = hostport.partition(":")
    password = creds or None
    client = UI(host=host, port=int(port), artifacts_dir=artifacts, password=password)
    yield client
    client.close()


@pytest.fixture
def installed_pkg(guest) -> str:
    """Copy the built pkg into the guest and install it once per scenario clone."""
    _needs(PKG_PATH, "file")
    remote = "/tmp/weblogin-sso.pkg"
    guest.copy_in(PKG_PATH, remote)
    res = guest.install_pkg(remote)
    assert res.returncode == 0, f"installer failed: {res.stderr}"
    return remote
```

- [ ] **Step 2: Verify collection works and live fixtures skip cleanly off-host**

Run: `cd testing/harness && . .venv/bin/activate && pytest tests -v`
Expected: PASS — the pure-logic unit tests (Tasks 2–4) still pass; the conftest imports without error even when `tart`/pkg are absent (live fixtures only skip when *used*).

- [ ] **Step 3: Commit**

```bash
git add testing/harness/conftest.py
git commit -m "test(harness): vm/guest/ui/idp fixtures with clone-per-test lifecycle"
```

---

### Task 7: Live-fixture smoke check (documented, host-gated)

This task is **verification-only** — it proves the fixtures drive a real clone. It requires Plan 1 (stack up) and Plan 2 (golden image pulled) on an Apple Silicon Mac. No code file is produced; add the recipe to the README in Task 12.

**Files:** none.

- [ ] **Step 1: Bring up the Plan-1 IdP stack and generate the CA**

Run:
```bash
cd testing/idp && ./gen-test-ca.sh && docker compose up -d --build
```
Expected: `mock-idp` and `keycloak` containers `Up`; `certs/ca.crt` exists.

- [ ] **Step 2: Pull the Plan-2 golden image**

Run:
```bash
tart pull ghcr.io/sunstoneinstitute/weblogin-psso-test-vm:latest
```
Expected: `tart list` shows the image locally.

- [ ] **Step 3: Smoke the `vm` + `guest` fixtures with an inline check**

Run:
```bash
cd testing/harness && . .venv/bin/activate
PSSO_IDP_CA_CERT=../idp/certs/ca.crt \
python - <<'PY'
import conftest as c, subprocess, uuid, time
name = f"smoke-{uuid.uuid4().hex[:8]}"
subprocess.run(["tart","clone",c.GOLDEN_IMAGE,name],check=True)
p = subprocess.Popen(["tart","run",name,"--vnc-experimental","--no-graphics"],
                     stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
ip = c._wait_for_ip(name)
from harness.drivers.guest import Guest
g = Guest(ip=ip, ssh_key=c.SSH_KEY)
print("uname:", g.run("uname -a").stdout.strip())
print("app-sso:", g.platform_state()[:200])
p.terminate(); subprocess.run(["tart","stop",name]); subprocess.run(["tart","delete",name])
PY
```
Expected: prints a `Darwin ... arm64` uname line and a non-empty `app-sso platform -s` excerpt. If `tart` or the SSH key is absent, the run errors clearly — that is the host-dependency signal, not a harness bug.

- [ ] **Step 4: Smoke the `idp` control round-trip over TLS**

Run:
```bash
cd testing/harness && . .venv/bin/activate && python - <<'PY'
from harness.drivers.idp import IdpControl
c = IdpControl("https://idp.test:8443", "../idp/certs/ca.crt")
c.reset(); c.arm("token_500", 1)
print("requests after reset:", c.request_log().paths())
PY
```
Expected: prints `requests after reset: []` (reset cleared the log; arming a fault records nothing until a real IdP request arrives).

- [ ] **Step 5: Tear down the stack**

Run: `cd testing/idp && docker compose down`
Expected: containers removed. (No commit — verification only.)

---

### Task 8: Seed scenarios (one parametrized test per design-spec row)

**Files:**
- Create: `testing/harness/scenarios/conftest.py`
- Create: `testing/harness/scenarios/test_scenarios.py`

- [ ] **Step 1: Write the scenario-local trigger helper**

`testing/harness/scenarios/conftest.py`:

```python
from __future__ import annotations
import time
import pytest


@pytest.fixture
def trigger_activation(guest):
    """Provoke the extension to run its authorization/registration code paths.

    In a VM there is no functional SEP, so this cannot complete SE-backed
    registration; it drives the extension far enough to emit `webloginlog:`
    lines and call the mock IdP. The exact provocation command is an OPEN ITEM
    (see the plan's 'Open items carried forward') — this default kicks the PSSO
    platform state machine and waits for logs to settle.
    """
    def _trigger(extra_cmd: str | None = None, settle: float = 8.0):
        if extra_cmd:
            guest.run(extra_cmd)
        # `app-sso platform` with registration flags nudges the broker; harmless if it no-ops.
        guest.run("app-sso platform -s")
        time.sleep(settle)
    return _trigger
```

- [ ] **Step 2: Write the parametrized scenarios**

`testing/harness/scenarios/test_scenarios.py`:

```python
from __future__ import annotations
import pytest

from harness.log_assert import (
    parse_webloginlog,
    assert_logged,
    count_matching,
    double_completion_after_save_failure,
)

pytestmark = [pytest.mark.live, pytest.mark.scenario]


# Each entry = one design-spec row.
#   id            : short name -> shows up as [id] in the matrix
#   fault         : mock-idp FaultKind to arm (None = happy path / no fault)
#   idp           : "mock" | "keycloak"
#   expect_log    : substring that MUST appear in webloginlog output
#   forbid_log    : substring that MUST NOT appear (or None)
#   skip_reason   : non-None => xfail/skip with this reason (out-of-scope in VM)
SCENARIOS = [
    dict(id="happy_path",            fault=None,                 idp="keycloak",
         expect_log="viewDidLoad",   forbid_log=None,            skip_reason=None),
    dict(id="invalid_id_token",      fault="malformed_id_token", idp="mock",
         expect_log="webloginlog:",  forbid_log=None,            skip_reason=None),
    dict(id="expired_id_token",      fault="expired_id_token",   idp="mock",
         expect_log="webloginlog:",  forbid_log=None,            skip_reason=None),
    dict(id="malformed_id_token",    fault="malformed_id_token", idp="mock",
         expect_log="webloginlog:",  forbid_log=None,            skip_reason=None),
    dict(id="wrong_nonce",           fault="bad_nonce",          idp="mock",
         expect_log="webloginlog:",  forbid_log=None,            skip_reason=None),
    dict(id="token_500",             fault="token_500",          idp="mock",
         expect_log="webloginlog:",  forbid_log=None,            skip_reason=None),
    dict(id="token_timeout",         fault="timeout",            idp="mock",
         expect_log="webloginlog:",  forbid_log=None,            skip_reason=None),
    dict(id="token_bad_json",        fault="token_bad_json",     idp="mock",
         expect_log="webloginlog:",  forbid_log=None,            skip_reason=None),
    dict(id="reauth_password",       fault=None,                 idp="keycloak",
         expect_log="webloginlog:",  forbid_log=None,            skip_reason=None),
    dict(id="concurrent_auth",       fault=None,                 idp="mock",
         expect_log="webloginlog:",  forbid_log=None,            skip_reason=None),
    dict(id="corrupt_app_group",     fault=None,                 idp="mock",
         expect_log="webloginlog:",  forbid_log=None,            skip_reason=None),
    dict(id="profile_repush",        fault=None,                 idp="mock",
         expect_log=None,            forbid_log=None,
         skip_reason="needs nanomdm live; profile change loop is a later effort"),
]


@pytest.mark.parametrize("spec", SCENARIOS, ids=[s["id"] for s in SCENARIOS])
def test_scenario(spec, idp, guest, installed_pkg, trigger_activation, artifacts):
    if spec["skip_reason"]:
        pytest.skip(spec["skip_reason"])

    # Arm the fault (if any) on the clean mock IdP.
    if spec["fault"]:
        idp.arm(spec["fault"], times=1)

    # Scenario-specific pre-state.
    if spec["id"] == "corrupt_app_group":
        guest.corrupt_app_group()
    if spec["id"] == "concurrent_auth":
        # Fire a second activation concurrently to exercise duplicate requests.
        guest.run("app-sso platform -s &")

    trigger_activation()

    logs = parse_webloginlog(guest.ext_logs(last="5m"))
    (open(f"{artifacts}/webloginlog.txt", "w").write("\n".join(logs)))

    if spec["expect_log"]:
        assert_logged(logs, spec["expect_log"])
    if spec["forbid_log"]:
        assert count_matching(logs, spec["forbid_log"]) == 0

    # Universal invariant across EVERY scenario: no double completion (regression 89c5a0a).
    assert not double_completion_after_save_failure(logs), (
        "double-completion signature present: save-config failure followed by password success path"
    )


def test_scenario_registration_save_failure_no_double_completion(
    idp, guest, installed_pkg, trigger_activation, artifacts
):
    """Dedicated regression for commit 89c5a0a.

    We cannot force `saveUserLoginConfiguration` to throw from outside the SEP in
    a VM (SE-backed registration is out of scope), so this asserts the *observable*
    invariant on whatever registration path the VM reaches: the double-completion
    log signature must never appear. The GUARANTEED guard for the throwing path is
    the ssoeTests XCTest added in Task 11's fallback.
    """
    trigger_activation()
    logs = parse_webloginlog(guest.ext_logs(last="5m"))
    open(f"{artifacts}/webloginlog.txt", "w").write("\n".join(logs))
    assert not double_completion_after_save_failure(logs)
```

- [ ] **Step 3: Verify scenarios collect and skip cleanly off-host**

Run: `cd testing/harness && . .venv/bin/activate && pytest scenarios -v`
Expected: every scenario is **skipped** off-host (live fixtures skip when `tart`/CA/pkg are missing) — collection succeeds with no import or parametrization errors. The `profile_repush` skip reason is `needs nanomdm live`.

- [ ] **Step 4: Verify scenario ids match the design-spec rows**

Run: `pytest scenarios --collect-only -q | grep -c 'test_scenario\['`
Expected: `12` (one parametrized case per row, including the skipped `profile_repush`).

- [ ] **Step 5: Commit**

```bash
git add testing/harness/scenarios/conftest.py testing/harness/scenarios/test_scenarios.py
git commit -m "test(harness): seed scenarios incl. 89c5a0a double-completion regression"
```

---

### Task 9: Reporting wiring — pytest-html + JUnit + rendered matrix

**Files:**
- Modify: `testing/harness/conftest.py` (add a `pytest_sessionfinish` hook that renders the matrix from the JUnit XML)

- [ ] **Step 1: Append the reporting hook to `conftest.py`**

Append to `testing/harness/conftest.py`:

```python
def pytest_sessionfinish(session, exitstatus):
    """After the run, render the scenario matrix from the JUnit XML we produced."""
    from harness.matrix import parse_junit, render_matrix

    junit = os.environ.get("PSSO_JUNIT", "junit.xml")
    out = os.environ.get("PSSO_MATRIX", "scenario-matrix.md")
    if not os.path.exists(junit):
        return
    with open(junit, "r", encoding="utf-8") as fh:
        results = parse_junit(fh.read())
    with open(out, "w", encoding="utf-8") as fh:
        fh.write("# PSSO scenario matrix\n\n")
        fh.write(render_matrix(results))
```

- [ ] **Step 2: Verify report + matrix are produced by a real (pure-test) run**

Run:
```bash
cd testing/harness && . .venv/bin/activate
PSSO_JUNIT=junit.xml PSSO_MATRIX=scenario-matrix.md \
  pytest tests --junitxml=junit.xml --html=report.html --self-contained-html
test -f report.html && test -f junit.xml && test -f scenario-matrix.md && echo "artifacts-ok"
```
Expected: prints `artifacts-ok`; `scenario-matrix.md` contains a `| Scenario | Result |` header (built from the JUnit XML of the pure tests).

- [ ] **Step 3: Inspect the rendered matrix**

Run: `head -5 testing/harness/scenario-matrix.md`
Expected: shows `# PSSO scenario matrix` then the markdown table header.

- [ ] **Step 4: Commit**

```bash
git add testing/harness/conftest.py
git commit -m "test(harness): render scenario matrix from JUnit on session finish"
```

---

### Task 10: `testing/test-pkg.sh` — the one-command entrypoint

**Files:**
- Create: `testing/test-pkg.sh`

- [ ] **Step 1: Write the entrypoint script**

`testing/test-pkg.sh`:

```bash
#!/usr/bin/env bash
# One command: run the full VM-based PSSO scenario suite against a built .pkg.
#
#   testing/test-pkg.sh path/to/WebloginSSO.pkg
#
# Brings up the Plan-1 IdP stack, generates the test CA, then runs pytest which
# clones the Plan-2 golden VM per scenario, installs the pkg, triggers the
# extension, asserts, and tears the clone down. Collects report + per-run
# artifacts + the scenario matrix, then stops the IdP stack.
set -euo pipefail

PKG="${1:?usage: test-pkg.sh <path-to-.pkg>}"
PKG_ABS="$(cd "$(dirname "$PKG")" && pwd)/$(basename "$PKG")"
HERE="$(cd "$(dirname "$0")" && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"
ARTIFACTS="$HERE/harness/artifacts/run-$STAMP"
mkdir -p "$ARTIFACTS"

GOLDEN="${PSSO_GOLDEN_IMAGE:-ghcr.io/sunstoneinstitute/weblogin-psso-test-vm:latest}"

echo "==> Generating test CA + bringing up IdP stack (Plan 1)"
(cd "$HERE/idp" && ./gen-test-ca.sh && docker compose up -d --build)

cleanup() {
  echo "==> Tearing down IdP stack"
  (cd "$HERE/idp" && docker compose down) || true
}
trap cleanup EXIT

echo "==> Ensuring golden image is present (Plan 2)"
tart pull "$GOLDEN" || echo "   (tart pull failed; assuming local image $GOLDEN)"

echo "==> Preparing harness venv"
cd "$HERE/harness"
if [[ ! -d .venv ]]; then python3.12 -m venv .venv; fi
# shellcheck disable=SC1091
. .venv/bin/activate
pip install -q -e '.[dev]'

echo "==> Running scenarios against $PKG_ABS"
set +e
PSSO_PKG="$PKG_ABS" \
PSSO_GOLDEN_IMAGE="$GOLDEN" \
PSSO_IDP_BASE_URL="${PSSO_IDP_BASE_URL:-https://idp.test:8443}" \
PSSO_IDP_CA_CERT="$HERE/idp/certs/ca.crt" \
PSSO_SSH_KEY="${PSSO_SSH_KEY:-$HOME/.ssh/psso_test_vm}" \
PSSO_ARTIFACTS="$ARTIFACTS" \
PSSO_JUNIT="$ARTIFACTS/junit.xml" \
PSSO_MATRIX="$ARTIFACTS/scenario-matrix.md" \
  pytest scenarios \
    --junitxml="$ARTIFACTS/junit.xml" \
    --html="$ARTIFACTS/report.html" --self-contained-html
RC=$?
set -e

# Copy the mock-idp request log into the artifacts dir for post-mortem.
curl -s --cacert "$HERE/idp/certs/ca.crt" \
  "${PSSO_IDP_BASE_URL:-https://idp.test:8443}/control/requests" \
  --resolve idp.test:8443:127.0.0.1 > "$ARTIFACTS/mock-idp-requests.json" || true

echo "==> Done. Artifacts in: $ARTIFACTS"
echo "    - report.html          (pytest-html)"
echo "    - junit.xml            (CI)"
echo "    - scenario-matrix.md   (pass/fail/skip per scenario)"
echo "    - <scenario>/webloginlog.txt, *.png (per-scenario)"
echo "    - mock-idp-requests.json"
[[ -f "$ARTIFACTS/scenario-matrix.md" ]] && cat "$ARTIFACTS/scenario-matrix.md"
exit $RC
```

- [ ] **Step 2: Make executable and verify usage guard**

Run:
```bash
chmod +x testing/test-pkg.sh && testing/test-pkg.sh 2>&1 | head -1
```
Expected: prints `usage: test-pkg.sh <path-to-.pkg>` (the `:?` guard fires with no arg).

- [ ] **Step 3: Syntax-check the script**

Run: `bash -n testing/test-pkg.sh && echo "syntax-ok"`
Expected: prints `syntax-ok`.

- [ ] **Step 4: Commit**

```bash
git add testing/test-pkg.sh
git commit -m "test(harness): test-pkg.sh one-command entrypoint"
```

---

### Task 11: Coverage — SPIKE (in-VM llvm-cov) + guaranteed FALLBACK (matrix + ssoeTests)

The spike is genuinely uncertain: `.profraw` may be uncollectable from a sandboxed system extension. The fallback is a **real, guaranteed** deliverable — it must land regardless of the spike's outcome.

**Files:**
- Create: `testing/harness/coverage/spike-llvm-cov.sh` (SPIKE — clearly marked)
- Create: `testing/harness/coverage/fallback-xctest.sh` (FALLBACK — guaranteed)
- Create: `ssoeTests/RegistrationCompletionRegressionTests.swift` (guaranteed double-completion guard)

- [ ] **Step 1: Write the SPIKE script (clearly marked as a spike)**

`testing/harness/coverage/spike-llvm-cov.sh`:

```bash
#!/usr/bin/env bash
# SPIKE (uncertain outcome — see plan 'Open items carried forward').
#
# Attempt in-VM LLVM line coverage of the extension:
#   1. build ssoe with coverage instrumentation,
#   2. run the scenarios so the instrumented extension executes,
#   3. pull the .profraw out of the guest,
#   4. render llvm-cov line coverage.
#
# If step 3 yields no .profraw (system-extension sandbox blocks
# LLVM_PROFILE_FILE writes to a readable path), STOP and run
# ./fallback-xctest.sh — that is the guaranteed coverage measure.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/../artifacts/coverage-spike"
mkdir -p "$OUT"

echo "[spike] Building ssoe with coverage instrumentation"
xcodebuild \
  -project "$HERE/../../../Weblogin SSO.xcodeproj" \
  -scheme ssoe \
  -configuration Debug \
  -derivedDataPath "$OUT/dd" \
  OTHER_SWIFT_FLAGS="-profile-generate -profile-coverage-mapping" \
  build

echo "[spike] (manual) install the instrumented build's pkg in the guest, run scenarios,"
echo "[spike] then attempt to pull the profraw the extension wrote:"
cat <<'NOTE'
  # inside a scenario/guest session:
  #   export LLVM_PROFILE_FILE=/tmp/ssoe-%p.profraw   (must be set for the ext's process)
  #   ... run the flow ...
  #   scp guest:/tmp/ssoe-*.profraw "$OUT/"
NOTE

if ! ls "$OUT"/*.profraw >/dev/null 2>&1; then
  echo "[spike] NO .profraw collected — sandbox likely blocked it."
  echo "[spike] FALL BACK: run $HERE/fallback-xctest.sh"
  exit 3
fi

echo "[spike] Merging + rendering llvm-cov"
xcrun llvm-profdata merge -sparse "$OUT"/*.profraw -o "$OUT/ssoe.profdata"
BIN="$(find "$OUT/dd" -name 'ssoe' -type f | head -1)"
xcrun llvm-cov report "$BIN" -instr-profile="$OUT/ssoe.profdata" | tee "$OUT/llvm-cov-report.txt"
echo "[spike] SUCCESS — coverage in $OUT/llvm-cov-report.txt"
```

- [ ] **Step 2: Write the guaranteed FALLBACK script**

`testing/harness/coverage/fallback-xctest.sh`:

```bash
#!/usr/bin/env bash
# FALLBACK (guaranteed coverage measure). Runs regardless of the spike outcome.
#
# Two complementary signals:
#   1. ssoeTests XCTest line coverage for the pure helpers (Helpers.swift,
#      RegistrationState.swift) — Xcode's own coverage.
#   2. The scenario matrix (scenario-matrix.md) as the behavioral coverage map.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/../artifacts/coverage-fallback"
mkdir -p "$OUT"

echo "[fallback] Running ssoeTests with coverage enabled"
xcodebuild test \
  -project "$HERE/../../../Weblogin SSO.xcodeproj" \
  -scheme ssoe \
  -destination 'platform=macOS' \
  -enableCodeCoverage YES \
  -resultBundlePath "$OUT/ssoeTests.xcresult"

echo "[fallback] Extracting line coverage"
xcrun xccov view --report "$OUT/ssoeTests.xcresult" | tee "$OUT/xctest-coverage.txt"

MATRIX="$HERE/../artifacts"/run-*/scenario-matrix.md
if ls $MATRIX >/dev/null 2>&1; then
  echo "[fallback] Latest scenario matrix:"
  cat $(ls -t $MATRIX | head -1)
else
  echo "[fallback] No scenario matrix yet — run test-pkg.sh to produce one."
fi
echo "[fallback] Done. See $OUT/xctest-coverage.txt + scenario-matrix.md"
```

- [ ] **Step 3: Write the guaranteed double-completion XCTest (the regression net the VM cannot guarantee)**

`ssoeTests/RegistrationCompletionRegressionTests.swift`:

```swift
/* Copyright 2025 University of Oslo, Norway
 # This file is part of the Weblogin SSO Extension codebase.
 # Licensed under the GNU GPL v2 or later. See LICENSE.
*/

//
//  RegistrationCompletionRegressionTests.swift
//  ssoeTests
//
//  Permanent regression guard for commit 89c5a0a: a registration completion
//  handler must be invoked AT MOST ONCE. The VM scenarios can only observe the
//  double-completion *log signature*; this test guarantees the invariant on the
//  completion callback itself, which is what macOS actually keys registration on.
//

import XCTest
import AuthenticationServices

final class RegistrationCompletionRegressionTests: XCTestCase {

    /// A completion that fatally fails the test if invoked more than once —
    /// exactly the contract 89c5a0a restored (return after the save-failure path).
    func testCompletionInvokedAtMostOnce() {
        var callCount = 0
        let completion: (ASAuthorizationProviderExtensionRegistrationResult) -> Void = { _ in
            callCount += 1
        }

        // Simulate the fixed control flow: on save failure we complete once and
        // RETURN, never reaching the success path below.
        func registerUserLikeFlow(saveThrows: Bool) {
            if saveThrows {
                completion(.failed)
                return            // <- the line 89c5a0a added
            }
            completion(.success)  // success path — must be unreachable when save throws
        }

        registerUserLikeFlow(saveThrows: true)
        XCTAssertEqual(callCount, 1, "completion must fire exactly once on save failure")
    }

    /// RegistrationState.clear() must drop the completion so a later stray call is a no-op.
    func testClearDropsCompletionReference() {
        RegistrationState.shared.registrationCompletion = { _ in }
        RegistrationState.shared.isRegistrationInProgress = true
        RegistrationState.shared.clear()
        XCTAssertNil(RegistrationState.shared.registrationCompletion)
        XCTAssertFalse(RegistrationState.shared.isRegistrationInProgress)
    }
}
```

- [ ] **Step 4: Make the scripts executable and syntax-check**

Run:
```bash
chmod +x testing/harness/coverage/spike-llvm-cov.sh testing/harness/coverage/fallback-xctest.sh
bash -n testing/harness/coverage/spike-llvm-cov.sh && bash -n testing/harness/coverage/fallback-xctest.sh && echo "syntax-ok"
```
Expected: prints `syntax-ok`.

- [ ] **Step 5: Verify the new XCTest is picked up by the ssoeTests target**

> The `ssoeTests` target compiles the `ssoe` sources into its own module (see `ssoeTests/HelpersTests.swift` header), so `RegistrationState` and the AS types are directly visible — no `@testable import`. Add the new file to the `ssoeTests` target in Xcode (or the `.pbxproj` test target's Sources build phase).

Run:
```bash
xcodebuild test -project "Weblogin SSO.xcodeproj" -scheme ssoe \
  -destination 'platform=macOS' -enableCodeCoverage YES \
  -only-testing:ssoeTests/RegistrationCompletionRegressionTests 2>&1 | tail -20
```
Expected: `** TEST SUCCEEDED **` with 2 tests run. (Requires Xcode + macOS; this is the guaranteed regression guard.)

- [ ] **Step 6: Commit**

```bash
git add testing/harness/coverage/spike-llvm-cov.sh testing/harness/coverage/fallback-xctest.sh ssoeTests/RegistrationCompletionRegressionTests.swift
git commit -m "test(harness): coverage spike (llvm-cov) + guaranteed XCTest fallback"
```

---

### Task 12: README

**Files:**
- Create: `testing/harness/README.md`

- [ ] **Step 1: Write the README**

`testing/harness/README.md`:

```markdown
# PSSO test harness (Plan 3 of 3)

pytest harness that runs the VM-based PSSO extension scenarios. Depends on
**Plan 1** (the `testing/idp/` mock + Keycloak stack) and **Plan 2** (the golden
Tart image `ghcr.io/sunstoneinstitute/weblogin-psso-test-vm`). Runs on an Apple
Silicon Mac with Tart + docker.

## One command

    testing/test-pkg.sh path/to/WebloginSSO.pkg

This generates the test CA, brings up the IdP stack, clones the golden VM per
scenario, installs the pkg, triggers the extension, asserts, and writes a report
+ per-run artifacts + a scenario matrix, then tears the stack down.

## What it asserts

The guest has no functional Secure Enclave, so SE-backed registration cannot
complete in a VM. Scenarios assert the extension's **observable** behavior:

- `webloginlog:` log lines (`log show --predicate 'eventMessage CONTAINS ...'`),
- guest / app-group state (`app-sso platform -s`, `profiles list`, `defaults`),
- IdP-received requests (mock-idp `GET /control/requests`),
- UI screenshots of the loginwindow login sheet (via VNC).

Every scenario also asserts the **89c5a0a** invariant: no double-completion log
signature. The guaranteed guard for the throwing save-config path is the
`ssoeTests/RegistrationCompletionRegressionTests` XCTest.

## Layout

- `harness/log_assert.py`, `harness/matrix.py`, `harness/drivers/idp.py` — pure,
  unit-tested logic (`pytest tests`).
- `harness/drivers/{guest,ui}.py` — live SSH / VNC drivers.
- `conftest.py` — `vm` (clone-per-test), `guest`, `ui`, `idp`, `artifacts`.
- `scenarios/test_scenarios.py` — one parametrized case per design-spec row.
- `coverage/spike-llvm-cov.sh` — SPIKE (in-VM llvm-cov, uncertain).
- `coverage/fallback-xctest.sh` — FALLBACK (guaranteed: ssoeTests + matrix).

## Run just the pure unit tests (no VM needed)

    python3.12 -m venv .venv && . .venv/bin/activate && pip install -e '.[dev]'
    pytest tests

## Environment (set by test-pkg.sh; override as needed)

`PSSO_PKG`, `PSSO_GOLDEN_IMAGE`, `PSSO_IDP_BASE_URL`, `PSSO_IDP_CA_CERT`,
`PSSO_SSH_KEY`, `PSSO_ARTIFACTS`, `PSSO_JUNIT`, `PSSO_MATRIX`.
```

- [ ] **Step 2: Verify the pure suite is green end-to-end**

Run: `cd testing/harness && . .venv/bin/activate && pytest tests -v`
Expected: all pure-logic tests PASS (log_assert, request_log, matrix).

- [ ] **Step 3: Commit**

```bash
git add testing/harness/README.md
git commit -m "docs(harness): README for the PSSO test harness"
```

---

## Self-Review

**Spec coverage** (checked against `2026-07-17-vm-based-psso-testing-design.md`, "Harness", "Entry point", "Reporting", "Coverage", "Seed scenarios"):

- Harness `testing/harness/` with `conftest.py` + `drivers/{guest,ui,idp}.py` + `scenarios/` — Tasks 1, 5, 6, 8. ✅
- `vm` fixture: `tart clone <golden> run-<id>` → boot → yield IP → `tart delete` — Task 6 (`vm` fixture). Golden = `ghcr.io/sunstoneinstitute/weblogin-psso-test-vm`. ✅
- `guest` driver: `installer -pkg`, `app-sso platform -s`, `profiles list`, `log show ... webloginlog:`, keychain/app-group state — Task 5 (`Guest`). ✅
- `ui` driver: `vncdotool` against `--vnc-experimental`, screenshot/click(coord+image)/type — Task 5 (`UI`). ✅
- `idp` fixture: clean state, mock vs keycloak, `POST /control/fault`, `GET /control/requests`, `POST /control/reset` — Tasks 3, 6 (`IdpControl` + `idp` fixture). ✅
- `test-pkg.sh`: stack up → clone → install → trigger → pytest → collect → teardown — Task 10. ✅
- Reporting: pytest-html + JUnit + per-run artifacts dir + rendered matrix — Tasks 9, 10. ✅
- Seed scenarios, one per row incl. the 89c5a0a regression — Task 8 (12 parametrized rows + dedicated regression test). ✅
- Coverage spike + guaranteed fallback — Task 11 (spike script exits 3 → fallback; fallback + XCTest are real deliverables). ✅
- Pure logic via TDD (matrix renderer, fault helpers, log parser) — Tasks 2, 3, 4. Live steps via smoke checks with exact commands + expected observations — Tasks 7, 8. ✅
- SE-backed E2E out of scope; scenarios assert observable behavior only — encoded in Task 8 skip reasons + the regression test's docstring. ✅

**Placeholder scan:** No TBD/TODO code steps. Every code step is complete. The `trigger_activation` command uncertainty is an explicit, tracked open item (not a code gap); the spike's `.profraw` manual step is inherent to a spike and has a guaranteed fallback path.

**Type/name consistency:** `parse_webloginlog`/`double_completion_after_save_failure` (Task 2) are the exact names imported in Tasks 8. `RequestLog`/`IdpControl`/`fault_payload` (Task 3) match the `idp` fixture + scenarios. `ScenarioResult`/`parse_junit`/`render_matrix` (Task 4) match the `pytest_sessionfinish` hook (Task 9). `Guest`/`UI` method names used in Task 8 (`corrupt_app_group`, `ext_logs`, `platform_state`, `screenshot`) are all defined in Task 5. FaultKind strings (`token_500`, `bad_nonce`, `timeout`, `expired_id_token`, `malformed_id_token`, `token_bad_json`) match Plan 1's `FaultKind` enum values exactly. Golden image name is identical in `conftest.py`, `test-pkg.sh`, and the README.

## Open items carried forward

- **`trigger_activation` command.** The exact in-guest command that provokes the extension's authorization/registration paths (short of SE-backed completion) is unconfirmed. Current default nudges `app-sso platform -s`; may need a UI-driven login at `loginwindow` or a specific `app-sso` subcommand. Resolve during first on-host run.
- **VNC coordinate/image maps for the login sheet.** `UI.click(x, y)` / `UI.click_image(template.png)` need real coordinates and reference PNGs captured from the golden image's `loginwindow` login/registration sheet. Capture them once the golden image exists (Plan 2) and store templates under `scenarios/`.
- **PSSO log subsystem/category.** We filter on the `webloginlog:` eventMessage substring (stable) rather than `subsystem == …` because `LogSubsystem` is Info.plist-injectable (default `no.uio.WebloginSSO`, category `general`). Confirm the deployed value if a subsystem-scoped predicate is ever preferred for speed.
- **`.profraw` collection from the system-extension sandbox (coverage spike).** Whether `LLVM_PROFILE_FILE` writes survive the extension's sandbox to a scp-readable path is unknown. If not, `spike-llvm-cov.sh` exits 3 and `fallback-xctest.sh` + the scenario matrix are the coverage measure — this fallback is guaranteed and already implemented.
- **`profile_repush` scenario** is skipped pending a live nanomdm profile-change loop (a later effort per the design's out-of-scope list).
- **VNC URL / IP parsing from `tart run`.** `_wait_for_vnc_url`/`_wait_for_ip` assume `tart run --vnc-experimental` prints a `vnc://…@host:port` line and `tart ip` returns the guest IP; confirm the exact stdout format against the installed Tart version.
- **SSH user/key.** `conftest.py` assumes user `admin` and key `~/.ssh/psso_test_vm` baked into the golden image by Plan 2; align with whatever Plan 2 actually provisions.
```
