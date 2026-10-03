"""Removes secrets and boilerplate from message text before it is stored or indexed.

Mirrors the intent of Cotabby's `TypingHistoryScrubber`: one-time codes, card numbers, IBANs,
credentials and API keys must never reach the memory, because anything stored here can surface
in a suggestion. Quoted replies and signatures are dropped from mail so a thread does not index
the same paragraph once per reply. Scrubbing is lossy on purpose; when in doubt, text is removed.
"""

from __future__ import annotations

import re

_REDACTED = "[redacted]"

_PATTERNS: list[re.Pattern[str]] = [
    # Card numbers: 13-19 digits, optionally grouped by spaces or dashes.
    re.compile(r"\b(?:\d[ -]?){13,19}\b"),
    # IBAN.
    re.compile(r"\b[A-Z]{2}\d{2}(?:[ ]?[A-Z0-9]{4}){3,7}(?:[ ]?[A-Z0-9]{1,3})?\b"),
    # API keys and tokens: long runs of key-like characters, and well-known prefixes.
    re.compile(r"\b(?:sk|pk|rk|ghp|gho|xox[abpr]|AKIA|AIza)[-_A-Za-z0-9]{12,}\b"),
    re.compile(r"\b[A-Za-z0-9_\-]{32,}\b"),
    # "password: x", "şifre: x", "pin 1234" and friends: drop the value after the label.
    re.compile(r"(?i)\b(password|passwd|pwd|parola|şifre|sifre|pin|passcode|token|secret)\b\s*[:=]?\s*\S+"),
]

# A message that is mainly a one-time code ("Your code is 482913", "Doğrulama kodu: 4829").
_OTP_MESSAGE = re.compile(
    r"(?i)\b(code|kod|kodu|otp|verification|doğrulama|dogrulama|one[- ]time)\b.{0,40}\b\d{4,8}\b"
)

# Mail quoting: "On <date>, <name> wrote:" and lines starting with ">".
_QUOTE_HEADER = re.compile(r"(?im)^(on .{5,200} wrote:|.{0,200} tarihinde .{0,100} yazdı:|-{2,} ?original message ?-{2,}|from: .+)$")
_SIGNATURE = re.compile(r"(?m)^(-- ?|—\s*|sent from my .+|iphone'umdan gönderildi.*)$", re.IGNORECASE)


def is_one_time_code(text: str) -> bool:
    return bool(_OTP_MESSAGE.search(text))


def strip_mail_quotes(text: str) -> str:
    """Keeps only what this message added: everything before the first quote header or signature
    delimiter, without `>`-quoted lines."""
    cut = len(text)
    for pattern in (_QUOTE_HEADER, _SIGNATURE):
        match = pattern.search(text)
        if match:
            cut = min(cut, match.start())
    kept = [line for line in text[:cut].splitlines() if not line.lstrip().startswith(">")]
    return "\n".join(kept).strip()


def scrub(text: str) -> str | None:
    """Returns the text with secrets redacted and whitespace collapsed, or None when nothing worth
    remembering is left (empty, or the whole message is a one-time code)."""
    if not text or is_one_time_code(text):
        return None
    cleaned = text
    for pattern in _PATTERNS:
        cleaned = pattern.sub(_REDACTED, cleaned)
    cleaned = re.sub(r"[ \t]+", " ", cleaned)
    cleaned = re.sub(r"\n{3,}", "\n\n", cleaned).strip()
    if not cleaned or cleaned == _REDACTED:
        return None
    return cleaned
