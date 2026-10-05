#!/usr/bin/env python3
"""Boot vanilla busybox QEMU and kexec -s. Env: ACCEL VIRTUALIZATION SMP CPU"""
import os, pty, select, time, sys, signal, errno

root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
log_path = os.environ.get("LOG", os.path.join(root, "build-out/vanilla-arm64/qemu-kexec.log"))
os.makedirs(os.path.dirname(log_path), exist_ok=True)
log = open(log_path, "wb", buffering=0)

env = os.environ.copy()
env.setdefault("ACCEL", "tcg")
env.setdefault("VIRTUALIZATION", "1")
env.setdefault("SMP", "1")

pid, fd = pty.fork()
if pid == 0:
    os.chdir(root)
    os.execve("/bin/bash", ["bash", "-lc", "./qemu/vanilla-arm64/run-qemu-vanilla.sh"], env)

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
            r, _, _ = select.select([fd], [], [], 1.0)
        except (OSError, ValueError):
            return None
        if fd in r:
            try:
                chunk = os.read(fd, 65536)
            except OSError as e:
                if e.errno == errno.EAGAIN:
                    continue
                if e.errno == errno.EIO:
                    return None
                raise
            if not chunk:
                return None
            write_log(chunk)
            buf += chunk
            if len(buf) > 2_000_000:
                drop = len(buf) - 1_000_000
                buf = buf[-1_000_000:]
                search_from = max(0, search_from - drop)
            window = buf[search_from:]
            for p in pats:
                idx = window.find(p)
                if idx >= 0:
                    search_from += idx + len(p)
                    return p.decode(errors="replace")
        wpid, status = os.waitpid(pid, os.WNOHANG)
        if wpid != 0:
            return None
    return None

def cleanup():
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

print("waiting for shell", flush=True)
hit = wait_for(["vanilla busybox guest", "Kernel panic", "VFS: Cannot open root"], 180)
print("first:", hit, flush=True)
if hit != "vanilla busybox guest":
    sys.stdout.buffer.write(buf[-5000:])
    cleanup()
    sys.exit(2)
wait_for(["# "], 20)
send(
    "kexec -s -l /boot/Image --command-line=\"$(cat /proc/cmdline)\"; "
    "echo KEXEC_LOAD_DONE\r"
)
hit = wait_for(["KEXEC_LOAD_DONE", "Kernel panic - not syncing"], 120)
print("load:", hit, flush=True)
if hit != "KEXEC_LOAD_DONE":
    sys.stdout.buffer.write(buf[-4000:])
    cleanup()
    sys.exit(3)
send("kexec -e\r")
hit = wait_for(["Booting Linux", "Linux version", "Kernel panic", "Oops"], 180)
print("kexec-e:", hit, flush=True)
if hit in ("Linux version", "Booting Linux"):
    hit2 = wait_for(
        ["Kernel panic", "Oops", "c2c2c2c2", "vanilla busybox guest", "dev_proc_net_init"],
        180,
    )
    print("second:", hit2, flush=True)
    if hit2 == "vanilla busybox guest":
        print("SECOND KERNEL SHELL OK", flush=True)
    elif hit2:
        wait_for(["end Kernel panic"], 15)
sys.stdout.buffer.write(b"\n===== TAIL =====\n" + buf[-12000:] + b"\n")
print("log:", log_path, flush=True)
cleanup()
