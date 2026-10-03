"""Cotabby's local conversation memory service.

Cotabby (the Swift app) owns this process: it creates the virtual environment, starts the server
with `python -m cotabby_memory`, and talks to it over a Unix socket. The service reads message
history from local stores and APIs (connectors), keeps a normalized copy in its own SQLite store,
indexes it with LEANN, and answers retrieval queries scoped to one conversation or one person.

Nothing here opens a network listener; the only network traffic is what a cloud connector the
user signed into makes to its own API (Microsoft Graph, Slack), and model downloads.
"""

__version__ = "0.1.0"
PROTOCOL_VERSION = 1
