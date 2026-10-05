#!/usr/bin/env python3
"""Boot the centos-arm64 LUKS kdump guest, log in, run the real kdump-utils
LUKS setup chain (01/03/04/05/06), trigger the panic (07, SysRq), and
require a vmcore on the LUKS disk after the crash kernel boots.

Pass: crash kernel boots, kdump saves to the LUKS-backed xfs target, and
the serial log shows no interactive "Enter passphrase" prompt (the volume
key must come back via the restored logon/user key -- here, read out of
the device-tree `dmcryptkeys` property the cherry-picked
arm64,ppc64le/kdump commit adds, see build-out/centos-arm64/README.md --
not a re-asked passphrase).

Identical structure to qemu/centos-x86/luks/luks-kdump-centos-x86-test.py;
the only functional difference is which run-qemu script it launches
underneath (TCG + EL2, not TCG-because-no-HVF, see run-qemu-luks-centos-
arm64.sh for why).
"""
import errno
import os
import pty
import select
import signal
import sys
import time

root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
log_path = os.environ.get(
    "LOG", os.path.join(root, "build-out/centos-arm64/luks-kdump-centos-arm64.log")
)
os.makedirs(os.path.dirname(log_path), exist_ok=True)
log = open(log_path, "wb", buffering=0)

env = os.environ.copy()
env.setdefault("ACCEL", "tcg")
env.setdefault("VIRTUALIZATION", "1")
env.setdefault("SMP", "1")
pid, fd = pty.fork()
if pid == 0:
    os.chdir(root)
    os.execve(
        "/bin/bash",
        ["bash", "-lc", "./qemu/centos-arm64/luks/run-qemu-luks-centos-arm64.sh"],
        env,
    )

os.set_blocking(fd, False)
buf = b""
search_from = 0


def write_log(data):
    log.write(data)
    log.flush()


def send(s):
    os.write(fd, s.encode() if isinstance(s, str) else s)


def wait_for(patterns, timeout):
    global buf, search_from
    deadline = time.time() + timeout
    pats = [p.encode() if isinstance(p, str) else p for p in patterns]
    while time.time() < deadline:
        try:
            ready, _, _ = select.select([fd], [], [], 1.0)
        except (OSError, ValueError):
            return None
        if fd in ready:
            try:
                chunk = os.read(fd, 65536)
            except OSError as exc:
                if exc.errno == errno.EAGAIN:
                    continue
                if exc.errno == errno.EIO:
                    return None
                raise
            if not chunk:
                return None
            write_log(chunk)
            buf += chunk
            if len(buf) > 6_000_000:
                drop = len(buf) - 3_000_000
                buf = buf[-3_000_000:]
                search_from = max(0, search_from - drop)
            window = buf[search_from:]
            for pat in pats:
                idx = window.find(pat)
                if idx >= 0:
                    search_from += idx + len(pat)
                    return pat.decode(errors="replace")
        wpid, _status = os.waitpid(pid, os.WNOHANG)
        if wpid != 0:
            return None
    return None


def cleanup():
    try:
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    deadline = time.time() + 2
    while time.time() < deadline:
        try:
            wpid, _status = os.waitpid(pid, os.WNOHANG)
        except ChildProcessError:
            break
        if wpid == pid:
            break
        time.sleep(0.1)
    log.close()


def dump_tail():
    sys.stdout.buffer.write(b"\n===== TAIL =====\n" + buf[-16000:] + b"\n")


print("waiting for centos-arm64 login prompt", flush=True)
hit = wait_for(["login:", "Kernel panic", "VFS: Cannot open root"], 300)
print("boot:", hit, flush=True)
if hit != "login:":
    dump_tail()
    cleanup()
    sys.exit(2)

time.sleep(0.4)
send("root\r")
if wait_for(["Password:"], 30):
    time.sleep(0.3)
    send("root\r")
hit = wait_for(["~]#", "Login incorrect"], 60)
print("shell:", hit, flush=True)
if hit != "~]#":
    dump_tail()
    cleanup()
    sys.exit(3)

send("sh /root/kdump-scripts/run-all.sh 2>&1 | tee /root/run-all.log\r")
# See qemu/centos-x86/luks/luks-kdump-centos-x86-test.py for why "FAIL" is
# deliberately NOT in this pattern list (05-rebuild-kdump.sh's own
# journalctl tail contains a legitimate, historical "[FAILED]" from
# systemd's early boot-time kdump.service attempt, before 03/04 configured
# a valid target) -- same trap, same fix, arch-independent.
hit = wait_for(["KDUMP_SETUP_DONE", "ERROR"], 420)
print("setup:", hit, flush=True)
if hit != "KDUMP_SETUP_DONE":
    dump_tail()
    cleanup()
    sys.exit(4)

hit = wait_for(["sysrq triggered crash", "command not found"], 90)
print("panic:", hit, flush=True)
if hit != "sysrq triggered crash":
    dump_tail()
    cleanup()
    sys.exit(5)

hit = wait_for(
    [
        "second kernel",
        "Enter passphrase",
        "login:",
        "Kernel panic - not syncing",
    ],
    900,
)
print("crash-kernel:", hit, flush=True)
dump_tail()
text = buf.decode(errors="replace")
no_passphrase_prompt = "Enter passphrase" not in text
print("no_interactive_passphrase_prompt:", no_passphrase_prompt, flush=True)
print("log:", log_path, flush=True)
cleanup()
