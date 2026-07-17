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
