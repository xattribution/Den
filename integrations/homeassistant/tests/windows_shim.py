"""Lets Home Assistant's test harness run on a Windows development machine.

Home Assistant only runs on Linux and macOS, so its test plugin imports `fcntl` and `resource`
and blocks every socket (asyncio on Windows needs sockets for its own wake-up pipe). On Windows
this stubs the two modules and leaves socket creation on; `socket_allow_hosts(["127.0.0.1"])`
still keeps tests off the network. Everywhere else this module does nothing.

Loaded with `-p tests.windows_shim` (see pytest.ini) so it runs before the plugin imports.
"""

import sys
import types

if sys.platform == "win32":
    if "fcntl" not in sys.modules:
        fcntl = types.ModuleType("fcntl")
        fcntl.LOCK_SH, fcntl.LOCK_EX, fcntl.LOCK_NB, fcntl.LOCK_UN = 1, 2, 4, 8
        fcntl.flock = lambda *args, **kwargs: None
        fcntl.fcntl = lambda *args, **kwargs: 0
        sys.modules["fcntl"] = fcntl
    if "resource" not in sys.modules:
        resource = types.ModuleType("resource")
        resource.RLIMIT_NOFILE = 7
        resource.getrlimit = lambda *args: (8192, 8192)
        resource.setrlimit = lambda *args: None
        sys.modules["resource"] = resource

    import pytest_socket

    pytest_socket.disable_socket = lambda allow_unix_socket=False: None
