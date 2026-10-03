"""The registry of memory sources the service knows how to read."""

from __future__ import annotations

from .base import Connector
from .documents import DocumentsConnector


def all_connectors() -> dict[str, Connector]:
    connectors: list[Connector] = [DocumentsConnector()]
    return {connector.id: connector for connector in connectors}
