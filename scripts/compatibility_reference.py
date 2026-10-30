#!/usr/bin/env python3
"""Development-only frozen clock/UUID adapter for the unmodified Python MCP."""
import uuid
import orbit
import mcp_server

sequence = 0


def deterministic_uuid():
    global sequence
    sequence += 1
    return uuid.UUID(f'00000000-0000-4000-8000-{sequence:012x}')


uuid.uuid4 = deterministic_uuid
orbit.now = lambda: '2026-10-30T12:00:00.000000+00:00'
mcp_server.main()
