"""Encryption for everything the service stores about messages.

Why: the store sits in Application Support, where file permissions keep other users out but not
other apps running as the same user, while the history it aggregates is protected at its source
(WhatsApp's and Mail's stores need Full Disk Access). Encrypting at rest keeps the copy as private
as the original.

How:
- One 256-bit master key, kept in Cotabby's Keychain and handed to the service on stdin at start.
- `seal`/`open`: AES-256-GCM with a random 96-bit nonce per value, for text that must be read back
  (message text, sender, subject, titles, conversation ids).
- `tag`: HMAC-SHA256 for values that must be *matched* but never read back (a title the user is
  looking at, a participant, a conversation key), so lookups work without storing plaintext.
- Separate subkeys for the two (HKDF-style expansion), so a tag can never be confused with, or
  help attack, a ciphertext.
"""

from __future__ import annotations

import hashlib
import hmac
import os

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

_NONCE_BYTES = 12
_CHECK_PLAINTEXT = "cotabby-memory-key-check-v1"


class KeyMismatch(Exception):
    """The store was encrypted with a different key (the Keychain item was reset or replaced)."""


def _expand(master: bytes, label: bytes) -> bytes:
    # HKDF-Expand with a single block (32 bytes); the master key is already uniformly random, so
    # the extract step adds nothing.
    return hmac.new(master, label + b"\x01", hashlib.sha256).digest()


class Vault:
    def __init__(self, key: bytes):
        if len(key) != 32:
            raise ValueError("memory key must be 32 bytes")
        self._aead = AESGCM(_expand(key, b"cotabby-memory enc"))
        self._mac_key = _expand(key, b"cotabby-memory mac")

    def seal(self, text: str | None) -> bytes | None:
        if text is None:
            return None
        nonce = os.urandom(_NONCE_BYTES)
        return nonce + self._aead.encrypt(nonce, text.encode("utf-8"), None)

    def open(self, blob: bytes | None) -> str | None:
        if blob is None:
            return None
        nonce, ciphertext = blob[:_NONCE_BYTES], blob[_NONCE_BYTES:]
        return self._aead.decrypt(nonce, ciphertext, None).decode("utf-8")

    def tag(self, value: str) -> str:
        """A deterministic, non-reversible key for matching `value` (128 bits, hex)."""
        return hmac.new(self._mac_key, value.encode("utf-8"), hashlib.sha256).hexdigest()[:32]

    def check_value(self) -> bytes:
        return self.seal(_CHECK_PLAINTEXT)  # type: ignore[return-value]

    def verify(self, check_value: bytes) -> None:
        try:
            if self.open(check_value) == _CHECK_PLAINTEXT:
                return
        except Exception:  # noqa: BLE001 - any failure means the key does not fit
            pass
        raise KeyMismatch("This memory was encrypted with a different key.")
