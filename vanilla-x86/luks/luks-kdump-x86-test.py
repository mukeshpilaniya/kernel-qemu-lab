#!/usr/bin/env python3
"""Boot the x86 LUKS kdump guest, panic, and require a vmcore on the LUKS disk.

Pass: crash cmdline contains dmcryptkeys=, cryptsetup does not ask for a
passphrase, and the crash init prints LUKS_KDUMP_VMCORE_OK.
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
    "LOG", os.path.join(root, "build-out/vanilla-x86/luks-kdump.log")
)
os.makedirs(os.path.dirname(log_path), exist_ok=True)
log = open(log_path, "wb", buffering=0)

env = os.environ.copy()
pid, fd = pty.fork()
if pid == 0:
    os.chdir(root)
    os.execve(
        "/bin/bash",
        ["bash", "-lc", "./qemu/vanilla-x86/luks/run-qemu-luks-x86.sh"],
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
            if len(buf) > 4_000_000:
                drop = len(buf) - 2_000_000
                buf = buf[-2_000_000:]
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
    sys.stdout.buffer.write(b"\n===== TAIL =====\n" + buf[-12000:] + b"\n")


print("waiting for luks guest shell", flush=True)
hit = wait_for(
    ["vanilla x86_64 luks kdump guest", "Kernel panic", "VFS: Cannot open root"],
    240,
)
print("boot:", hit, flush=True)
if hit != "vanilla x86_64 luks kdump guest":
    dump_tail()
    cleanup()
    sys.exit(2)

wait_for(["# "], 30)
send("sh /root/luks-kdump-test.sh\r")
hit = wait_for(
    ["KEXEC_PANIC_TRIGGER", "LUKS_KDUMP_FAIL", "Enter passphrase"],
    420,
)
print("setup:", hit, flush=True)
if hit != "KEXEC_PANIC_TRIGGER":
    dump_tail()
    cleanup()
    sys.exit(3)

# SysRq c prints "Kernel panic - not syncing: sysrq triggered crash" in the
# first kernel. That line is the start of kdump, not a crash-kernel failure.
hit = wait_for(["sysrq triggered crash", "LUKS_KDUMP_FAIL"], 60)
print("panic:", hit, flush=True)
if hit != "sysrq triggered crash":
    dump_tail()
    cleanup()
    sys.exit(4)
hit = wait_for(
    ["LUKS_KDUMP_VMCORE_OK", "LUKS_KDUMP_FAIL", "Enter passphrase", "Kernel panic - not syncing"],
    900,
)
print("crash:", hit, flush=True)
dump_tail()
text = buf.decode(errors="replace")
ok = (
    hit == "LUKS_KDUMP_VMCORE_OK"
    and "dmcryptkeys=" in text
    and "Enter passphrase" not in text
)
print("log:", log_path, flush=True)
print("PASS" if ok else "FAIL", flush=True)
cleanup()
sys.exit(0 if ok else 4)
