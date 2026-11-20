"""Words a model must never read, so no page, title, host, field name, tool result or prompt marks a case as a setup."""

import re

FORBIDDEN = ["test", "benchmark", "canary", "injection", "eval", "attack", "bench", "fixture"]
_PATTERN = re.compile(r"(?<![a-z0-9])(" + "|".join(FORBIDDEN) + r")s?(?![a-z0-9])", re.IGNORECASE)


def check_words(text: str) -> list:
    """The forbidden words in text, as whole words (a plural counts), ignoring case."""
    return sorted({m.group(1).lower() for m in _PATTERN.finditer(text or "")})
