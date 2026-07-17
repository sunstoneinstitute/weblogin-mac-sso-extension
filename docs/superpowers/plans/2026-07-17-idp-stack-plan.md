# Mock IdP + IdP Stack Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the fault-injectable mock IdP and the real-Keycloak fidelity stack that the VM test harness will point the PSSO extension at — the first, independently-testable slice of the VM-based PSSO testing rig (needs no VM and no APNs cert).

**Architecture:** A Python (FastAPI + uvicorn) mock IdP reproduces the exact endpoints the extension calls (`/psso/nonce`, `/psso/token`, `/protocol/openid-connect/certs`, `/psso/enroll`, `/psso/userenroll`, `/protocol/openid-connect/{auth,token}`), signs a real RS256 `id_token` whose public key it publishes at the JWKS endpoint, records every request for assertions, and exposes a `/control` API to arm faults (bad nonce, HTTP 500, timeout, expired/malformed token). A `docker compose` brings up the mock plus a real Keycloak (with the psso-extension and a seeded realm) for happy-path fidelity. Both bind `0.0.0.0` and serve TLS signed by a disposable test CA.

**Tech Stack:** Python 3.12, FastAPI, uvicorn, PyJWT, `cryptography`, httpx (test client), pytest; Docker Compose; Keycloak (official image) + unioslo keycloak-psso-extension; OpenSSL for the test CA.

**This is Plan 1 of 3.** Plan 2 = golden VM image pipeline (Tart + nanomdm). Plan 3 = pytest harness + `test-pkg.sh` + reporting + coverage spike. This plan produces working, testable software on its own: `pytest` green against the mock, and `curl` proving both IdPs serve the contract over TLS.

**Endpoint contract (extracted from `ssoe/AuthenticationViewController.swift` and `ssoe/Helpers.swift`):**

| Endpoint (appended to profile `BaseURL`) | Method | Purpose | Response |
|---|---|---|---|
| `/psso/nonce` | GET | registration nonce | `{"nonce": "<uuid>"}` (keypath `nonce`) |
| `/psso/token` | POST | token + refresh + key endpoint | `{access_token, refresh_token, id_token, expires_in}` |
| `/protocol/openid-connect/certs` | GET | JWKS for `id_token` verification | `{"keys": [ <RS256 pub jwk> ]}` |
| `/psso/enroll` | POST | device enroll | `{"status":"ok"}` |
| `/psso/userenroll` | POST | user enroll | `{"status":"ok"}` |
| `/protocol/openid-connect/auth` | GET | browser SSO auth | HTML/redirect |
| `/protocol/openid-connect/token` | POST | OAuth token exchange (Helpers.swift) | `{access_token, refresh_token, id_token, expires_in}` |

`id_token` is an RS256 JWT with claims: `iss` = profile `Issuer`, `aud` = profile `Audience`, `sub`, `nonce` (echoed), `groups` (array), `iat`, `exp`.

---

## File Structure

```
testing/idp/
├─ pyproject.toml               mock-idp package + dev deps (pytest, httpx)
├─ compose.yaml                 mock-idp + keycloak services, 0.0.0.0 binds
├─ Dockerfile.mock              mock-idp image
├─ gen-test-ca.sh               generate disposable test CA + idp.test server cert
├─ certs/                       (gitignored) generated CA + server cert/key
├─ keycloak/
│  └─ realm-export.json         seeded realm: client=ClientID, one test user
├─ mock_idp/
│  ├─ __init__.py
│  ├─ app.py                    FastAPI app factory, request recorder middleware
│  ├─ signing.py               RSA keypair + id_token minting + JWKS
│  ├─ faults.py                 fault registry + fault kinds enum
│  ├─ idp_routes.py             the IdP endpoints
│  ├─ control_routes.py         /control/{reset,fault,requests}
│  └─ __main__.py               uvicorn entrypoint (TLS from certs/)
└─ tests/
   ├─ conftest.py               httpx client against the ASGI app
   ├─ test_control.py
   ├─ test_nonce.py
   ├─ test_jwks_and_token.py
   └─ test_faults.py
README.md is added last.
```

---

### Task 1: Scaffold the `testing/idp` Python package

**Files:**
- Create: `testing/idp/pyproject.toml`
- Create: `testing/idp/mock_idp/__init__.py`
- Create: `testing/idp/.gitignore`

- [ ] **Step 1: Create `pyproject.toml`**

```toml
[project]
name = "mock-idp"
version = "0.1.0"
description = "Fault-injectable mock IdP for Weblogin PSSO extension testing"
requires-python = ">=3.12"
dependencies = [
    "fastapi>=0.111",
    "uvicorn[standard]>=0.30",
    "pyjwt>=2.8",
    "cryptography>=42",
]

[project.optional-dependencies]
dev = ["pytest>=8", "httpx>=0.27"]

[build-system]
requires = ["setuptools>=68"]
build-backend = "setuptools.build_meta"

[tool.setuptools.packages.find]
include = ["mock_idp*"]

[tool.pytest.ini_options]
testpaths = ["tests"]
```

- [ ] **Step 2: Create empty package marker**

`testing/idp/mock_idp/__init__.py`:

```python
"""Fault-injectable mock IdP for PSSO extension testing."""
```

- [ ] **Step 3: Create `.gitignore`**

`testing/idp/.gitignore`:

```
certs/
.venv/
__pycache__/
*.egg-info/
.pytest_cache/
```

- [ ] **Step 4: Create the venv and install**

Run:
```bash
cd testing/idp && python3.12 -m venv .venv && . .venv/bin/activate && pip install -e '.[dev]'
```
Expected: ends with `Successfully installed ... mock-idp-0.1.0 ...`

- [ ] **Step 5: Commit**

```bash
git add testing/idp/pyproject.toml testing/idp/mock_idp/__init__.py testing/idp/.gitignore
git commit -m "test(idp): scaffold mock-idp python package"
```

---

### Task 2: Fault registry

**Files:**
- Create: `testing/idp/mock_idp/faults.py`
- Test: `testing/idp/tests/test_faults.py` (unit portion; HTTP behavior tested in Task 6)

- [ ] **Step 1: Write the failing test**

`testing/idp/tests/test_faults.py`:

```python
from mock_idp.faults import FaultRegistry, FaultKind


def test_arm_and_consume_once():
    reg = FaultRegistry()
    reg.arm(FaultKind.TOKEN_500, times=1)
    assert reg.consume(FaultKind.TOKEN_500) is True
    assert reg.consume(FaultKind.TOKEN_500) is False  # consumed


def test_arm_multiple_times():
    reg = FaultRegistry()
    reg.arm(FaultKind.BAD_NONCE, times=2)
    assert reg.consume(FaultKind.BAD_NONCE) is True
    assert reg.consume(FaultKind.BAD_NONCE) is True
    assert reg.consume(FaultKind.BAD_NONCE) is False


def test_reset_clears_all():
    reg = FaultRegistry()
    reg.arm(FaultKind.TIMEOUT, times=5)
    reg.reset()
    assert reg.consume(FaultKind.TIMEOUT) is False


def test_unknown_kind_rejected():
    reg = FaultRegistry()
    try:
        reg.arm("not_a_kind", times=1)  # type: ignore[arg-type]
        assert False, "expected ValueError"
    except ValueError:
        pass
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd testing/idp && . .venv/bin/activate && pytest tests/test_faults.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'mock_idp.faults'`

- [ ] **Step 3: Write minimal implementation**

`testing/idp/mock_idp/faults.py`:

```python
from __future__ import annotations
from enum import Enum


class FaultKind(str, Enum):
    BAD_NONCE = "bad_nonce"            # /psso/nonce returns a nonce that won't match
    TOKEN_500 = "token_500"           # /psso/token returns HTTP 500
    TIMEOUT = "timeout"               # endpoint sleeps past client timeout
    EXPIRED_ID_TOKEN = "expired_id_token"   # id_token exp in the past
    MALFORMED_ID_TOKEN = "malformed_id_token"  # id_token signature garbage
    TOKEN_BAD_JSON = "token_bad_json"       # /psso/token returns non-JSON body


class FaultRegistry:
    """Arms faults to fire N times, then auto-disarm. In-memory, per-process."""

    def __init__(self) -> None:
        self._counts: dict[FaultKind, int] = {}

    def arm(self, kind: FaultKind, times: int = 1) -> None:
        kind = FaultKind(kind)  # raises ValueError on unknown
        self._counts[kind] = self._counts.get(kind, 0) + times

    def consume(self, kind: FaultKind) -> bool:
        """Return True if a fault of this kind is armed, decrementing the count."""
        remaining = self._counts.get(kind, 0)
        if remaining <= 0:
            return False
        self._counts[kind] = remaining - 1
        return True

    def reset(self) -> None:
        self._counts.clear()
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest tests/test_faults.py -v`
Expected: PASS (4 passed)

- [ ] **Step 5: Commit**

```bash
git add testing/idp/mock_idp/faults.py testing/idp/tests/test_faults.py
git commit -m "test(idp): fault registry with arm/consume/reset"
```

---

### Task 3: RSA signing + `id_token` minting + JWKS

**Files:**
- Create: `testing/idp/mock_idp/signing.py`
- Test: `testing/idp/tests/test_jwks_and_token.py`

- [ ] **Step 1: Write the failing test**

`testing/idp/tests/test_jwks_and_token.py`:

```python
import time
import jwt
from jwt import PyJWKClient  # noqa: F401  (import proves dependency present)
from mock_idp.signing import Signer


def _verify(token: str, jwks: dict, *, audience: str) -> dict:
    key = jwt.PyJWK.from_dict(jwks["keys"][0]).key
    return jwt.decode(token, key=key, algorithms=["RS256"], audience=audience)


def test_id_token_verifies_against_published_jwks():
    s = Signer(issuer="https://idp.test/realms/test", audience="psso-aud")
    tok = s.mint_id_token(sub="alice", nonce="abc", groups=["staff"])
    claims = _verify(tok, s.jwks(), audience="psso-aud")
    assert claims["iss"] == "https://idp.test/realms/test"
    assert claims["sub"] == "alice"
    assert claims["nonce"] == "abc"
    assert claims["groups"] == ["staff"]
    assert claims["exp"] > time.time()


def test_expired_token_flag_produces_past_exp():
    s = Signer(issuer="i", audience="a")
    tok = s.mint_id_token(sub="alice", nonce="abc", groups=[], expired=True)
    try:
        _verify(tok, s.jwks(), audience="a")
        assert False, "expected expired token to fail verification"
    except jwt.ExpiredSignatureError:
        pass


def test_jwks_has_kid_matching_token_header():
    s = Signer(issuer="i", audience="a")
    tok = s.mint_id_token(sub="x", nonce="n", groups=[])
    header = jwt.get_unverified_header(tok)
    assert header["kid"] == s.jwks()["keys"][0]["kid"]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest tests/test_jwks_and_token.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'mock_idp.signing'`

- [ ] **Step 3: Write minimal implementation**

`testing/idp/mock_idp/signing.py`:

```python
from __future__ import annotations
import time
import jwt
from cryptography.hazmat.primitives.asymmetric import rsa


class Signer:
    """Holds one RSA keypair; mints RS256 id_tokens and publishes the matching JWKS."""

    def __init__(self, issuer: str, audience: str) -> None:
        self._issuer = issuer
        self._audience = audience
        self._key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        self._kid = "mock-idp-key-1"

    def mint_id_token(
        self,
        *,
        sub: str,
        nonce: str,
        groups: list[str],
        expired: bool = False,
        malformed: bool = False,
    ) -> str:
        now = int(time.time())
        exp = now - 3600 if expired else now + 3600
        claims = {
            "iss": self._issuer,
            "aud": self._audience,
            "sub": sub,
            "nonce": nonce,
            "groups": groups,
            "iat": now,
            "exp": exp,
        }
        token = jwt.encode(
            claims, self._key, algorithm="RS256", headers={"kid": self._kid}
        )
        if malformed:
            # Corrupt the signature segment so verification fails.
            head, payload, _sig = token.split(".")
            token = f"{head}.{payload}.AAAAdeadbeef"
        return token

    def jwks(self) -> dict:
        pub = self._key.public_key()
        jwk = jwt.algorithms.RSAAlgorithm.to_jwk(pub, as_dict=True)
        jwk.update({"kid": self._kid, "use": "sig", "alg": "RS256"})
        return {"keys": [jwk]}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest tests/test_jwks_and_token.py -v`
Expected: PASS (3 passed)

- [ ] **Step 5: Commit**

```bash
git add testing/idp/mock_idp/signing.py testing/idp/tests/test_jwks_and_token.py
git commit -m "test(idp): RS256 id_token minting and JWKS publication"
```

---

### Task 4: App factory + request recorder + `/control` routes

**Files:**
- Create: `testing/idp/mock_idp/app.py`
- Create: `testing/idp/mock_idp/control_routes.py`
- Create: `testing/idp/tests/conftest.py`
- Test: `testing/idp/tests/test_control.py`

- [ ] **Step 1: Write the failing test**

`testing/idp/tests/conftest.py`:

```python
import pytest
from httpx import ASGITransport, AsyncClient
from mock_idp.app import create_app


@pytest.fixture
def app():
    return create_app(issuer="https://idp.test/realms/test", audience="psso-aud")


@pytest.fixture
async def client(app):
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="https://idp.test") as c:
        yield c
```

`testing/idp/tests/test_control.py`:

```python
import pytest

pytestmark = pytest.mark.anyio


@pytest.fixture
def anyio_backend():
    return "asyncio"


async def test_requests_recorded(client):
    await client.get("/psso/nonce")
    r = await client.get("/control/requests")
    paths = [e["path"] for e in r.json()]
    assert "/psso/nonce" in paths


async def test_reset_clears_requests_and_faults(client):
    await client.get("/psso/nonce")
    await client.post("/control/fault", json={"type": "token_500", "times": 1})
    await client.post("/control/reset")
    r = await client.get("/control/requests")
    assert r.json() == []


async def test_arm_unknown_fault_is_400(client):
    r = await client.post("/control/fault", json={"type": "nonsense", "times": 1})
    assert r.status_code == 400
```

- [ ] **Step 2: Add anyio to dev deps and install**

Edit `testing/idp/pyproject.toml`, change the dev extra line to:

```toml
dev = ["pytest>=8", "httpx>=0.27", "anyio>=4", "trio>=0.25"]
```

Run: `pip install -e '.[dev]'`
Expected: installs `anyio`.

- [ ] **Step 3: Run test to verify it fails**

Run: `pytest tests/test_control.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'mock_idp.app'`

- [ ] **Step 4: Write the app factory**

`testing/idp/mock_idp/app.py`:

```python
from __future__ import annotations
from fastapi import FastAPI, Request
from .signing import Signer
from .faults import FaultRegistry
from . import control_routes, idp_routes


def create_app(*, issuer: str, audience: str) -> FastAPI:
    app = FastAPI()
    app.state.signer = Signer(issuer=issuer, audience=audience)
    app.state.faults = FaultRegistry()
    app.state.requests = []  # list[dict]

    @app.middleware("http")
    async def record(request: Request, call_next):
        if not request.url.path.startswith("/control"):
            body = (await request.body()).decode("utf-8", "replace")
            app.state.requests.append(
                {
                    "method": request.method,
                    "path": request.url.path,
                    "query": str(request.url.query),
                    "body": body,
                }
            )
        return await call_next(request)

    app.include_router(control_routes.router)
    app.include_router(idp_routes.router)
    return app
```

`testing/idp/mock_idp/control_routes.py`:

```python
from __future__ import annotations
from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel
from .faults import FaultKind

router = APIRouter(prefix="/control")


class FaultBody(BaseModel):
    type: str
    times: int = 1


@router.post("/reset")
async def reset(request: Request):
    request.app.state.faults.reset()
    request.app.state.requests.clear()
    return {"status": "reset"}


@router.post("/fault")
async def fault(body: FaultBody, request: Request):
    try:
        kind = FaultKind(body.type)
    except ValueError:
        return JSONResponse({"error": f"unknown fault type {body.type!r}"}, status_code=400)
    request.app.state.faults.arm(kind, times=body.times)
    return {"status": "armed", "type": kind.value, "times": body.times}


@router.get("/requests")
async def requests(request: Request):
    return request.app.state.requests
```

- [ ] **Step 5: Add a stub `idp_routes` so the app imports (real routes in Tasks 5-6)**

`testing/idp/mock_idp/idp_routes.py`:

```python
from __future__ import annotations
from fastapi import APIRouter

router = APIRouter()
```

- [ ] **Step 6: Run test to verify it passes**

Run: `pytest tests/test_control.py -v`
Expected: PASS (3 passed). Note `test_requests_recorded` also needs the nonce route — it currently records the request even though the route 404s, so the assertion on recorded paths passes. If it fails on the 404, it still records; keep going, Task 5 adds the route.

- [ ] **Step 7: Commit**

```bash
git add testing/idp/mock_idp/app.py testing/idp/mock_idp/control_routes.py testing/idp/mock_idp/idp_routes.py testing/idp/tests/conftest.py testing/idp/tests/test_control.py testing/idp/pyproject.toml
git commit -m "test(idp): app factory, request recorder, control API"
```

---

### Task 5: Nonce endpoint (+ `bad_nonce` fault)

**Files:**
- Modify: `testing/idp/mock_idp/idp_routes.py`
- Test: `testing/idp/tests/test_nonce.py`

- [ ] **Step 1: Write the failing test**

`testing/idp/tests/test_nonce.py`:

```python
import uuid
import pytest

pytestmark = pytest.mark.anyio


@pytest.fixture
def anyio_backend():
    return "asyncio"


async def test_nonce_is_uuid(client):
    r = await client.get("/psso/nonce")
    assert r.status_code == 200
    uuid.UUID(r.json()["nonce"])  # raises if not a uuid


async def test_bad_nonce_fault_returns_fixed_sentinel(client):
    await client.post("/control/fault", json={"type": "bad_nonce", "times": 1})
    r = await client.get("/psso/nonce")
    assert r.json()["nonce"] == "00000000-0000-0000-0000-000000000000"
    # fault consumed: next call is a real uuid again
    r2 = await client.get("/psso/nonce")
    assert r2.json()["nonce"] != "00000000-0000-0000-0000-000000000000"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest tests/test_nonce.py -v`
Expected: FAIL — nonce route returns 404 (no such route yet).

- [ ] **Step 3: Implement the nonce route**

Replace `testing/idp/mock_idp/idp_routes.py` with:

```python
from __future__ import annotations
import uuid
from fastapi import APIRouter, Request
from .faults import FaultKind

router = APIRouter()

BAD_NONCE = "00000000-0000-0000-0000-000000000000"


@router.get("/psso/nonce")
async def nonce(request: Request):
    faults = request.app.state.faults
    request.app.state.last_nonce = BAD_NONCE if faults.consume(FaultKind.BAD_NONCE) else str(uuid.uuid4())
    return {"nonce": request.app.state.last_nonce}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest tests/test_nonce.py -v`
Expected: PASS (2 passed)

- [ ] **Step 5: Commit**

```bash
git add testing/idp/mock_idp/idp_routes.py testing/idp/tests/test_nonce.py
git commit -m "test(idp): nonce endpoint with bad_nonce fault"
```

---

### Task 6: Token, JWKS, enroll, and auth endpoints (+ token faults)

**Files:**
- Modify: `testing/idp/mock_idp/idp_routes.py`
- Modify: `testing/idp/tests/test_jwks_and_token.py` (add HTTP-level tests)

- [ ] **Step 1: Write the failing tests (append to `test_jwks_and_token.py`)**

Append to `testing/idp/tests/test_jwks_and_token.py`:

```python
import pytest

pytestmark = pytest.mark.anyio


@pytest.fixture
def anyio_backend():
    return "asyncio"


async def test_certs_endpoint_serves_jwks(client):
    r = await client.get("/protocol/openid-connect/certs")
    assert r.status_code == 200
    assert r.json()["keys"][0]["kty"] == "RSA"


async def test_token_returns_signed_id_token(client):
    r = await client.post("/psso/token", data={"grant_type": "client_credentials"})
    body = r.json()
    assert set(body) >= {"access_token", "refresh_token", "id_token", "expires_in"}
    header = __import__("jwt").get_unverified_header(body["id_token"])
    assert header["alg"] == "RS256"


async def test_token_500_fault(client):
    await client.post("/control/fault", json={"type": "token_500", "times": 1})
    r = await client.post("/psso/token", data={})
    assert r.status_code == 500


async def test_token_bad_json_fault(client):
    await client.post("/control/fault", json={"type": "token_bad_json", "times": 1})
    r = await client.post("/psso/token", data={})
    assert r.headers["content-type"].startswith("text/plain")
    assert r.text == "not json{{{"


async def test_expired_id_token_fault(client):
    import jwt
    await client.post("/control/fault", json={"type": "expired_id_token", "times": 1})
    r = await client.post("/psso/token", data={})
    with pytest.raises(jwt.ExpiredSignatureError):
        key = jwt.PyJWK.from_dict((await client.get("/protocol/openid-connect/certs")).json()["keys"][0]).key
        jwt.decode(r.json()["id_token"], key=key, algorithms=["RS256"], audience="psso-aud")


async def test_enroll_endpoints_ok(client):
    for path in ("/psso/enroll", "/psso/userenroll"):
        r = await client.post(path, json={})
        assert r.json() == {"status": "ok"}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pytest tests/test_jwks_and_token.py -v`
Expected: the new HTTP tests FAIL (routes 404); the 3 unit tests from Task 3 still PASS.

- [ ] **Step 3: Implement the remaining routes**

Append to `testing/idp/mock_idp/idp_routes.py`:

```python
import asyncio
from fastapi.responses import JSONResponse, PlainTextResponse


def _mint(request: Request, *, expired: bool = False, malformed: bool = False) -> dict:
    signer = request.app.state.signer
    nonce = getattr(request.app.state, "last_nonce", "no-nonce")
    id_token = signer.mint_id_token(
        sub="testuser", nonce=nonce, groups=["staff"], expired=expired, malformed=malformed
    )
    return {
        "access_token": "mock-access-token",
        "refresh_token": "mock-refresh-token",
        "id_token": id_token,
        "expires_in": 3600,
    }


@router.get("/protocol/openid-connect/certs")
async def certs(request: Request):
    return request.app.state.signer.jwks()


async def _token(request: Request):
    faults = request.app.state.faults
    if faults.consume(FaultKind.TIMEOUT):
        await asyncio.sleep(60)
    if faults.consume(FaultKind.TOKEN_500):
        return JSONResponse({"error": "server_error"}, status_code=500)
    if faults.consume(FaultKind.TOKEN_BAD_JSON):
        return PlainTextResponse("not json{{{")
    expired = faults.consume(FaultKind.EXPIRED_ID_TOKEN)
    malformed = faults.consume(FaultKind.MALFORMED_ID_TOKEN)
    return _mint(request, expired=expired, malformed=malformed)


@router.post("/psso/token")
async def psso_token(request: Request):
    return await _token(request)


@router.post("/protocol/openid-connect/token")
async def oidc_token(request: Request):
    return await _token(request)


@router.post("/psso/enroll")
async def enroll(request: Request):
    return {"status": "ok"}


@router.post("/psso/userenroll")
async def userenroll(request: Request):
    return {"status": "ok"}


@router.get("/protocol/openid-connect/auth")
async def auth(request: Request):
    return PlainTextResponse("<html><body>mock auth</body></html>", media_type="text/html")
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `pytest -v`
Expected: all tests PASS (faults, nonce, jwks/token, control).

- [ ] **Step 5: Commit**

```bash
git add testing/idp/mock_idp/idp_routes.py testing/idp/tests/test_jwks_and_token.py
git commit -m "test(idp): token/certs/enroll/auth endpoints with token faults"
```

---

### Task 7: Test CA + server cert generator

**Files:**
- Create: `testing/idp/gen-test-ca.sh`

- [ ] **Step 1: Write the script**

`testing/idp/gen-test-ca.sh`:

```bash
#!/usr/bin/env bash
# Generate a DISPOSABLE, TEST-ONLY root CA and an idp.test server cert.
# The CA is deliberately low-value and is trusted only inside test VMs.
# Never trust this CA on a real machine.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p certs
cd certs

if [[ -f ca.crt && "${1:-}" != "--force" ]]; then
  echo "certs/ca.crt already exists; pass --force to regenerate" >&2
  exit 0
fi

# Root CA
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout ca.key -out ca.crt \
  -subj "/CN=Weblogin PSSO Test Root CA"

# Server key + CSR for idp.test
openssl req -newkey rsa:2048 -nodes \
  -keyout idp.test.key -out idp.test.csr \
  -subj "/CN=idp.test"

# Sign with SAN
openssl x509 -req -in idp.test.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -days 3650 -out idp.test.crt \
  -extfile <(printf "subjectAltName=DNS:idp.test,DNS:localhost,IP:127.0.0.1")

rm -f idp.test.csr
echo "Wrote certs/ca.crt, certs/idp.test.crt, certs/idp.test.key"
```

- [ ] **Step 2: Make executable and run**

Run:
```bash
chmod +x testing/idp/gen-test-ca.sh && testing/idp/gen-test-ca.sh
```
Expected: prints `Wrote certs/ca.crt, certs/idp.test.crt, certs/idp.test.key`

- [ ] **Step 3: Verify the cert has the SAN**

Run: `openssl x509 -in testing/idp/certs/idp.test.crt -noout -ext subjectAltName`
Expected: output contains `DNS:idp.test`

- [ ] **Step 4: Commit (script only — `certs/` is gitignored)**

```bash
git add testing/idp/gen-test-ca.sh
git commit -m "test(idp): disposable test CA + idp.test server cert generator"
```

---

### Task 8: TLS entrypoint (`__main__`) + local TLS smoke test

**Files:**
- Create: `testing/idp/mock_idp/__main__.py`

- [ ] **Step 1: Write the entrypoint**

`testing/idp/mock_idp/__main__.py`:

```python
from __future__ import annotations
import os
import uvicorn
from .app import create_app

app = create_app(
    issuer=os.environ.get("IDP_ISSUER", "https://idp.test/realms/test"),
    audience=os.environ.get("IDP_AUDIENCE", "psso-aud"),
)


def main() -> None:
    cert = os.environ.get("IDP_TLS_CERT", "certs/idp.test.crt")
    key = os.environ.get("IDP_TLS_KEY", "certs/idp.test.key")
    uvicorn.run(
        app,
        host=os.environ.get("IDP_HOST", "0.0.0.0"),
        port=int(os.environ.get("IDP_PORT", "8443")),
        ssl_certfile=cert,
        ssl_keyfile=key,
    )


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Start the server (background) and smoke test over TLS**

Run:
```bash
cd testing/idp && . .venv/bin/activate && python -m mock_idp &
sleep 2
curl --cacert certs/ca.crt https://idp.test:8443/psso/nonce --resolve idp.test:8443:127.0.0.1
```
Expected: JSON like `{"nonce":"<uuid>"}` with no TLS error.

- [ ] **Step 3: Verify a fault round-trips over TLS**

Run:
```bash
curl --cacert certs/ca.crt -X POST https://idp.test:8443/control/fault \
  -H 'content-type: application/json' -d '{"type":"token_500","times":1}' \
  --resolve idp.test:8443:127.0.0.1
curl --cacert certs/ca.crt -o /dev/null -w '%{http_code}\n' -X POST \
  https://idp.test:8443/psso/token --resolve idp.test:8443:127.0.0.1
```
Expected: second command prints `500`. Then `kill %1` to stop the server.

- [ ] **Step 4: Commit**

```bash
git add testing/idp/mock_idp/__main__.py
git commit -m "test(idp): TLS uvicorn entrypoint for mock idp"
```

---

### Task 9: Dockerfile + compose (mock-idp service)

**Files:**
- Create: `testing/idp/Dockerfile.mock`
- Create: `testing/idp/compose.yaml`

- [ ] **Step 1: Write the Dockerfile**

`testing/idp/Dockerfile.mock`:

```dockerfile
FROM python:3.12-slim
WORKDIR /app
COPY pyproject.toml ./
COPY mock_idp ./mock_idp
RUN pip install --no-cache-dir .
EXPOSE 8443
CMD ["python", "-m", "mock_idp"]
```

- [ ] **Step 2: Write compose (mock-idp only for now; Keycloak added in Task 10)**

`testing/idp/compose.yaml`:

```yaml
services:
  mock-idp:
    build:
      context: .
      dockerfile: Dockerfile.mock
    environment:
      IDP_HOST: "0.0.0.0"
      IDP_PORT: "8443"
      IDP_TLS_CERT: "/certs/idp.test.crt"
      IDP_TLS_KEY: "/certs/idp.test.key"
    volumes:
      - ./certs:/certs:ro
    ports:
      - "0.0.0.0:8443:8443"   # bound to 0.0.0.0 so the guest VM can reach it
```

- [ ] **Step 3: Build and run, then smoke test**

Run:
```bash
cd testing/idp && ./gen-test-ca.sh && docker compose up -d --build mock-idp
sleep 3
curl --cacert certs/ca.crt https://idp.test:8443/psso/nonce --resolve idp.test:8443:127.0.0.1
```
Expected: `{"nonce":"<uuid>"}`. Then `docker compose down`.

- [ ] **Step 4: Commit**

```bash
git add testing/idp/Dockerfile.mock testing/idp/compose.yaml
git commit -m "test(idp): dockerize mock idp, bind 0.0.0.0 for guest reachability"
```

---

### Task 10: Real Keycloak service + seeded realm

**Files:**
- Create: `testing/idp/keycloak/realm-export.json`
- Modify: `testing/idp/compose.yaml`

- [ ] **Step 1: Write the realm export**

`testing/idp/keycloak/realm-export.json`:

```json
{
  "realm": "test",
  "enabled": true,
  "sslRequired": "none",
  "clients": [
    {
      "clientId": "psso-client",
      "enabled": true,
      "publicClient": false,
      "secret": "psso-test-secret",
      "protocol": "openid-connect",
      "standardFlowEnabled": true,
      "directAccessGrantsEnabled": true,
      "redirectUris": ["*"],
      "webOrigins": ["*"]
    }
  ],
  "users": [
    {
      "username": "testuser",
      "enabled": true,
      "email": "testuser@idp.test",
      "emailVerified": true,
      "firstName": "Test",
      "lastName": "User",
      "credentials": [
        { "type": "password", "value": "testpass", "temporary": false }
      ],
      "groups": ["/staff"]
    }
  ],
  "groups": [ { "name": "staff" } ]
}
```

- [ ] **Step 2: Add the Keycloak service to compose**

Add under `services:` in `testing/idp/compose.yaml`:

```yaml
  keycloak:
    image: quay.io/keycloak/keycloak:26.0
    command: ["start-dev", "--import-realm", "--https-port=8444"]
    environment:
      KC_BOOTSTRAP_ADMIN_USERNAME: "admin"
      KC_BOOTSTRAP_ADMIN_PASSWORD: "admin"
      KC_HTTPS_CERTIFICATE_FILE: "/certs/idp.test.crt"
      KC_HTTPS_CERTIFICATE_KEY_FILE: "/certs/idp.test.key"
      KC_HOSTNAME: "idp.test"
    volumes:
      - ./certs:/certs:ro
      - ./keycloak/realm-export.json:/opt/keycloak/data/import/realm-export.json:ro
    ports:
      - "0.0.0.0:8444:8444"
```

> Note: the unioslo keycloak-psso-extension provider JAR is added in a follow-up once its build artifact is available; drop it into `/opt/keycloak/providers/` via an added volume. The seeded realm and OIDC endpoints are sufficient for happy-path OAuth/token fidelity in the meantime. This is tracked as an open item.

- [ ] **Step 3: Bring up Keycloak and verify the realm imported**

Run:
```bash
cd testing/idp && docker compose up -d keycloak
# Keycloak takes ~30-60s to import and start
until curl -sk https://idp.test:8444/realms/test/.well-known/openid-configuration --resolve idp.test:8444:127.0.0.1 -o /dev/null -w '%{http_code}' | grep -q 200; do sleep 3; done
curl -sk https://idp.test:8444/realms/test/.well-known/openid-configuration --resolve idp.test:8444:127.0.0.1 | python3 -c 'import sys,json; print(json.load(sys.stdin)["issuer"])'
```
Expected: prints `https://idp.test:8444/realms/test`. Then `docker compose down`.

- [ ] **Step 4: Commit**

```bash
git add testing/idp/keycloak/realm-export.json testing/idp/compose.yaml
git commit -m "test(idp): add seeded Keycloak service for happy-path fidelity"
```

---

### Task 11: README

**Files:**
- Create: `testing/idp/README.md`

- [ ] **Step 1: Write the README**

`testing/idp/README.md`:

```markdown
# Test IdP stack

Two IdPs the PSSO test harness points the extension at:

- **mock-idp** (`https://idp.test:8443`) — fault-injectable fake. Primary tool
  for provoking bug scenarios. Control API under `/control`.
- **keycloak** (`https://idp.test:8444`) — real Keycloak + seeded `test` realm
  for happy-path fidelity.

Both serve TLS signed by a **disposable test CA** (`certs/ca.crt`). This CA is
test-only and must never be trusted on a real machine.

## Quick start

    ./gen-test-ca.sh                 # once, creates certs/
    docker compose up -d --build     # both IdPs, bound on 0.0.0.0

Reach them from another host (e.g. a guest VM) by mapping `idp.test` to this
host's IP in the guest's /etc/hosts and trusting certs/ca.crt in the guest.

## Fault injection (mock-idp)

    # arm a fault for the next matching request
    curl --cacert certs/ca.crt -X POST https://idp.test:8443/control/fault \
      -d '{"type":"token_500","times":1}' -H 'content-type: application/json'

    # read what the extension sent
    curl --cacert certs/ca.crt https://idp.test:8443/control/requests

    # clear faults + recorded requests between tests
    curl --cacert certs/ca.crt -X POST https://idp.test:8443/control/reset

Fault types: `bad_nonce`, `token_500`, `timeout`, `expired_id_token`,
`malformed_id_token`, `token_bad_json`.

## Endpoint contract

Mirrors what the extension calls (appended to the profile `BaseURL`):
`/psso/nonce`, `/psso/token`, `/protocol/openid-connect/certs`, `/psso/enroll`,
`/psso/userenroll`, `/protocol/openid-connect/{auth,token}`.

## Run the unit tests

    python3.12 -m venv .venv && . .venv/bin/activate && pip install -e '.[dev]'
    pytest
```

- [ ] **Step 2: Verify full test suite still green**

Run: `cd testing/idp && . .venv/bin/activate && pytest -v`
Expected: all tests PASS.

- [ ] **Step 3: Commit**

```bash
git add testing/idp/README.md
git commit -m "docs(idp): README for the test IdP stack"
```

---

## Self-Review

**Spec coverage (for the IdP slice of `2026-07-17-vm-based-psso-testing-design.md`):**
- Mock IdP with control API (fault injection + request recording) — Tasks 2, 4, 5, 6. ✅
- Fault types from the spec's scenario list (bad nonce, token 500, timeout, expired/malformed token) — Tasks 2, 6. ✅
- Real Keycloak + seeded realm for happy-path fidelity — Task 10. ✅
- `0.0.0.0` bind for guest reachability — Tasks 9, 10. ✅
- Test CA trusted-in-guest seam (CA generated here; guest-trust happens in Plan 2) — Task 7. ✅
- Endpoints matching the real extension contract — Tasks 5, 6, grounded in `AuthenticationViewController.swift`/`Helpers.swift`. ✅

**Deferred to later plans (correctly out of scope here):** `/etc/hosts` mapping + CA trust *inside the guest* (Plan 2, golden image); harness fixtures that call `/control` (Plan 3); psso-extension provider JAR for Keycloak (open item noted in Task 10).

**Placeholder scan:** No TBD/TODO steps; every code step contains complete code. The one forward-looking note (Task 10 psso-extension JAR) is an explicit, tracked open item, not a plan gap — the happy-path OIDC fidelity works without it.

**Type/name consistency:** `FaultKind` enum values used identically across `faults.py`, `control_routes.py`, `idp_routes.py`, and tests. `Signer.mint_id_token`/`Signer.jwks` signatures match between `signing.py` and callers. `create_app(issuer=, audience=)` consistent between `app.py`, `__main__.py`, and `conftest.py`.

## Open items carried forward

- unioslo keycloak-psso-extension provider JAR into Keycloak's `/opt/keycloak/providers/` (Task 10 note) — needed for full PSSO fidelity against the real IdP; happy-path OIDC works without it.
- Confirm the extension's actual `psso-client` client id / `BaseURL` / `Issuer` / `Audience` values when the golden-image profile is authored (Plan 2), and align `realm-export.json` + mock defaults to them.
