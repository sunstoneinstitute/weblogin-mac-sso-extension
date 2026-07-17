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
