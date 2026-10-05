#!/usr/bin/env python3
"""Boot QEMU, kexec -s -l/-e, report panic vs login. Env: ACCEL VIRTUALIZATION SMP CPU EXTRA_APPEND"""
import os, pty, select, time, sys, signal, errno

root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
log_path = os.environ.get("LOG", os.path.join(root, "build-out/centos-arm64/qemu-kexec-nomops.log"))
log = open(log_path, "wb", buffering=0)

env = os.environ.copy()
env.setdefault("ACCEL", "tcg")
env.setdefault("VIRTUALIZATION", "1")
env.setdefault("SMP", "1")

pid, fd = pty.fork()
if pid == 0:
    os.chdir(root)
    os.execve("/bin/bash", ["bash", "-lc", "./qemu/centos-arm64/run-qemu.sh"], env)

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

print(f"log: {log_path}", flush=True)
hit = wait_for(["centos-stream-10 login:", "Kernel panic - not syncing"], 300)
print(f"first wait: {hit}", flush=True)
if hit is None or (hit and hit.startswith("Kernel panic")):
    cleanup()
    sys.exit(2)

time.sleep(0.4)
send("root\r")
if wait_for(["Password:"], 60):
    time.sleep(0.3)
    send("root\r")
hit = wait_for(["~]#", "Login incorrect"], 120)
print(f"shell: {hit}", flush=True)
if hit != "~]#":
    cleanup()
    sys.exit(3)

send(
    "for d in /sys/bus/platform/drivers/physmap-flash/*/driver; do "
    "[ -e \"$d\" ] || continue; "
    "echo \"$(basename \"$(dirname \"$d\")\")\" > /sys/bus/platform/drivers/physmap-flash/unbind; "
    "done; "
    "kexec -s -l /boot/Image --initrd=/boot/initramfs.img "
    "--command-line=\"$(cat /proc/cmdline)\"; "
    "echo KEXEC_LOAD_DONE\r"
)
hit = wait_for(["KEXEC_LOAD_DONE", "Kernel panic"], 180)
print(f"after load: {hit}", flush=True)
if hit != "KEXEC_LOAD_DONE":
    cleanup()
    sys.exit(4)

send("kexec -e\r")
hit = wait_for(
    ["Booting Linux", "Linux version", "Kernel panic", "Oops", "c2c2c2c2"],
    180,
)
print(f"after kexec -e: {hit}", flush=True)
if hit in ("Linux version", "Booting Linux"):
    hit2 = wait_for(
        ["Kernel panic", "Oops", "c2c2c2c2", "centos-stream-10 login:", "dev_proc_net_init"],
        180,
    )
    print(f"second kernel: {hit2}", flush=True)
    if hit2 in ("Oops", "c2c2c2c2", "dev_proc_net_init", "Kernel panic"):
        wait_for(["end Kernel panic"], 30)

sys.stdout.buffer.write(b"\n===== TAIL =====\n" + buf[-8000:] + b"\n===== END =====\n")
cleanup()
