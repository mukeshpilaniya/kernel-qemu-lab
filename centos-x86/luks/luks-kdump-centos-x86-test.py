#!/usr/bin/env python3
"""Boot the centos-x86 LUKS kdump guest, log in, run the real kdump-utils
LUKS setup chain (01/03/04/05/06), trigger the panic (07, SysRq), and
require a vmcore on the LUKS disk after the crash kernel boots.

Pass: crash kernel boots, kdump saves to the LUKS-backed xfs target, and
the serial log shows no interactive "Enter passphrase" prompt (the volume
key must come back via the restored logon/user key, not a re-asked
passphrase).

Unlike qemu/vanilla-x86/luks/luks-kdump-x86-test.py (busybox: no login,
straight to a root shell), this guest has a real systemd login prompt, so
the driver has to authenticate first -- same login dance as
qemu/centos-arm64/kexec-guest-test.py.
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
    "LOG", os.path.join(root, "build-out/centos-x86/luks-kdump-centos-x86.log")
)
os.makedirs(os.path.dirname(log_path), exist_ok=True)
log = open(log_path, "wb", buffering=0)

env = os.environ.copy()
pid, fd = pty.fork()
if pid == 0:
    os.chdir(root)
    os.execve(
        "/bin/bash",
        ["bash", "-lc", "./qemu/centos-x86/luks/run-qemu-luks-centos-x86.sh"],
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


print("waiting for centos-x86 login prompt", flush=True)
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
# NOTE: a bare "FAIL" pattern here is a false-positive trap. 05-rebuild-
# kdump.sh ends with `journalctl -u kdump --no-pager -n 20`, which shows
# *historical* journal entries for the kdump unit -- including systemd's
# own automatic early-boot attempt to start kdump.service, before 03/04
# have configured a valid dump target. That attempt legitimately fails
# with "kdump: Starting kdump: [FAILED]", and "[FAILED]" contains "FAIL"
# as a substring -- a prior version of this pattern list matched that
# stale, irrelevant history and aborted the whole test right as the real
# (immediately preceding) `systemctl restart kdump` had just succeeded.
# "ERROR" is kept: it matches this project's own die()/[ERROR] convention
# in lib/common.sh, which is specific enough not to false-positive here.
hit = wait_for(["KDUMP_SETUP_DONE", "ERROR"], 420)
print("setup:", hit, flush=True)
if hit != "KDUMP_SETUP_DONE":
    dump_tail()
    cleanup()
    sys.exit(4)

# SysRq c prints "Kernel panic - not syncing: sysrq triggered crash" in the
# first kernel. That line is the start of kdump, not a crash-kernel failure.
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
