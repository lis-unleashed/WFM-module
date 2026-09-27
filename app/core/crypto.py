"""Encrypts Xero OAuth tokens before they're stored in xero_connection.

Uses Fernet (AES plus an HMAC, from the cryptography package). The keys come
from WFM_TOKEN_ENCRYPTION_KEYS, newest first. New tokens are encrypted with the
newest key, and older keys can still decrypt what they encrypted, so a key can
be rotated without losing the saved Xero connection.
"""

from cryptography.fernet import Fernet, InvalidToken, MultiFernet


class TokenDecryptionError(Exception):
    """A stored token can't be decrypted with any of the configured keys."""


def generate_key() -> str:
    return Fernet.generate_key().decode("ascii")


def parse_keys(value: str) -> list[Fernet]:
    """Comma-separated keys, newest first. Error messages never include a key."""
    keys = [k.strip() for k in value.split(",") if k.strip()]
    if not keys:
        raise ValueError("no encryption keys given")
    fernets = []
    for position, key in enumerate(keys, start=1):
        try:
            fernets.append(Fernet(key))
        except ValueError:
            raise ValueError(
                f"encryption key {position} isn't a valid key (make one with `wfm generate-key`)"
            ) from None
    return fernets


class TokenCipher:
    def __init__(self, keys: str) -> None:
        self._fernet = MultiFernet(parse_keys(keys))

    def encrypt(self, token: str) -> bytes:
        return self._fernet.encrypt(token.encode("utf-8"))

    def decrypt(self, stored: bytes) -> str:
        try:
            return self._fernet.decrypt(stored).decode("utf-8")
        except InvalidToken:
            raise TokenDecryptionError(
                "the stored token can't be decrypted with any of the configured keys"
            ) from None

    def rotate(self, stored: bytes) -> bytes:
        """Re-encrypts a stored token with the newest key, so older keys can be retired."""
        return self._fernet.rotate(stored)
