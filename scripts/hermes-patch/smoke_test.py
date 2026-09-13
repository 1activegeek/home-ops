"""Behavioural check for the carried per-user USER.md patch.

Run by scripts/hermes-patch/verify.sh inside the hermes-agent image, with the
patched modules mounted over their originals exactly as the Deployment does.
Static greps only prove the patch landed; this proves it WORKS — which is the
part that matters when forward-porting it onto a refactored release.
"""
import inspect
from enum import Enum

import tools.memory_tool_store as st
from tools.memory_tool import load_on_disk_store  # noqa: F401  (import must not raise)


class _Platform(Enum):
    """Stand-in for gateway.config.Platform: a plain Enum, so str() is
    'Platform.MATRIX' and only .value is the wire name. The gateway passes the
    enum while agent_init passes a bare string — both must derive the SAME key
    or one person's USER.md silently forks in two."""
    MATRIX = "matrix"
    SLACK = "slack"


def main() -> None:
    anon = st.MemoryStore()
    slack_str = st.MemoryStore(user_id="U03G89W2A10", platform="slack")
    slack_enum = st.MemoryStore(user_id="U03G89W2A10", platform=_Platform.SLACK)
    matrix = st.MemoryStore(user_id="@shawn:matrix.org", platform=_Platform.MATRIX)
    hostile = st.MemoryStore(user_id="../../etc/passwd", platform="matrix")

    for label, store in (("anon", anon), ("slack(str)", slack_str),
                         ("slack(enum)", slack_enum), ("matrix", matrix),
                         ("hostile", hostile)):
        print(f"  {label:12} USER.md -> {store._path_for('user')}")

    u = lambda s: str(s._path_for("user"))      # noqa: E731
    m = lambda s: str(s._path_for("memory"))    # noqa: E731

    assert "users" not in u(anon), "no identity must keep the global USER.md"
    assert u(slack_str).endswith("memories/users/slack-U03G89W2A10/USER.md"), u(slack_str)
    assert u(slack_str) == u(slack_enum), "Platform enum and str must derive the same key"
    assert m(anon) == m(slack_str), "MEMORY.md is global and must not be partitioned"
    assert ".." not in u(hostile) and u(hostile).count("/users/") == 1, "path traversal"
    assert u(slack_str) != u(matrix), "different platforms must not collide"

    for store in (anon, slack_str, matrix, hostile):
        store.load_from_disk()
    print("  load_from_disk(): OK on the global store and 3 partitions")

    params = inspect.signature(load_on_disk_store).parameters
    assert "user_id" in params and "platform" in params, params
    gateway_store = load_on_disk_store(user_id="U03G89W2A10", platform="slack")
    assert u(gateway_store) == u(slack_str), "gateway approval path must hit the agent's partition"
    print("  load_on_disk_store(identity): routes to the agent's partition")

    import agent.agent_init  # noqa: F401
    import gateway.slash_commands  # noqa: F401
    print("  agent_init + slash_commands import cleanly")
    print("SMOKE TEST PASSED")


if __name__ == "__main__":
    main()
