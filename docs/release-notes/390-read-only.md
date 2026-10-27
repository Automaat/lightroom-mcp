# Read-only sessions

Set `LIGHTROOM_MCP_READ_ONLY=true` (or `1`) to list and accept only read tools from the enabled toolsets. Write calls are rejected before dispatch, including calls forwarded through another bridge. File exports are writes and are blocked. Mask and Develop read tools retain their temporary view switching and restoration.

The desktop bundle exposes a **Read-only mode** switch. Restart the server after changing either setting. `false`, `0`, unset or empty keeps the existing behavior; other values fail startup. Values are case-sensitive and surrounding whitespace is ignored.
