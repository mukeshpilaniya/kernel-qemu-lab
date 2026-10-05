#!/usr/bin/env python3
"""Boot vanilla x86_64 QEMU and wait for the busybox shell."""
import os, pty, select, time, sys, signal, errno

root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
log_path = os.path.join(root, "build-out/vanilla-x86/qemu-boot.log")
os.makedirs(os.path.dirname(log_path), exist_ok=True)
log = open(log_path, "wb", buffering=0)

pid, fd = pty.fork()
if pid == 0:
    os.chdir(root)
    os.execve("/bin/bash", ["bash", "-lc", "./qemu/vanilla-x86/run-qemu-vanilla-x86.sh"], os.environ.copy())

os.set_blocking(fd, False)
buf = b""

def wait_for(patterns, timeout):
    global buf
    deadline = time.time() + timeout
    pats = [p.encode() for p in patterns]
    while time.time() < deadline:
        try:
            r, _, _ = select.select([fd], [], [], 1.0)
        except (OSError, ValueError):
            return None
        if fd in r:
            try:
                chunk = os.read(fd, 65536)
            except OSError as e:
                if e.errno in (errno.EAGAIN, errno.EIO):
                    if e.errno == errno.EIO:
                        return None
                    continue
                raise
            if not chunk:
                return None
            log.write(chunk)
            log.flush()
            buf += chunk
            for p in pats:
                if p in buf:
                    return p.decode()
        wpid, status = os.waitpid(pid, os.WNOHANG)
        if wpid != 0:
            return None
    return None

print("waiting for x86 busybox...", flush=True)
hit = wait_for(["vanilla x86_64 busybox guest", "Kernel panic", "VFS: Cannot open root"], 180)
print("result:", hit, flush=True)
sys.stdout.buffer.write(b"\n===== TAIL =====\n" + buf[-6000:] + b"\n")
try:
    os.kill(pid, signal.SIGTERM)
    time.sleep(0.5)
    os.kill(pid, signal.SIGKILL)
except ProcessLookupError:
    pass
try:
    os.waitpid(pid, 0)
except ChildProcessError:
    pass
log.close()
sys.exit(0 if hit == "vanilla x86_64 busybox guest" else 2)
