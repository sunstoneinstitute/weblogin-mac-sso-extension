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
