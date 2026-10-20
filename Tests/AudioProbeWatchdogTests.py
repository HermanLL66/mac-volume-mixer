#!/usr/bin/env python3
"""Test a separately compiled AudioProbe without opening any audio device.

Usage: python3 Tests/AudioProbeWatchdogTests.py /absolute/path/to/AudioProbe
Both cases use --watchdog-fixture, whose main thread blocks in pause().
"""

import json
import os
import select
import subprocess
import sys
import time


def deadline_test(probe):
    began = time.monotonic()
    child = subprocess.Popen(
        [probe, "--watchdog-fixture", "0.15"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    try:
        stdout, stderr = child.communicate(timeout=3.5)
    except subprocess.TimeoutExpired:
        child.kill()
        child.communicate()
        raise AssertionError("Probe survived its absolute deadline with the main thread blocked")
    elapsed = time.monotonic() - began
    assert "watchdog-ready" in stdout, (stdout, stderr)
    assert child.returncode == 124, (child.returncode, stderr)
    assert 1.9 <= elapsed < 3.5, elapsed
    return {"exitCode": child.returncode, "elapsedSeconds": elapsed}


def parent_exit_test(probe):
    # The child inherits this short-lived parent's stdout. The outer runner sees
    # EOF only once BOTH parent and AudioProbe have closed their descriptors.
    parent_code = """
import os, subprocess, sys, time
child = subprocess.Popen([sys.argv[1], '--watchdog-fixture', '30'], stdout=sys.stdout, stderr=sys.stderr)
print('child-pid=' + str(child.pid), flush=True)
time.sleep(0.3)
os._exit(0)
"""
    parent = subprocess.Popen(
        [sys.executable, "-c", parent_code, probe],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=False,
    )
    child_pid = None
    saw_eof = False
    received = b""
    began = time.monotonic()
    cutoff = began + 3
    try:
        while time.monotonic() < cutoff:
            ready, _, _ = select.select([parent.stdout], [], [], max(0, cutoff - time.monotonic()))
            if not ready:
                break
            data = os.read(parent.stdout.fileno(), 4096)
            if not data:
                saw_eof = True
                break
            received += data
            for line in received.splitlines():
                if line.startswith(b"child-pid="):
                    child_pid = int(line.split(b"=", 1)[1])
        else:
            raise AssertionError("Parent-loss fixture exceeded its deadline")
        elapsed = time.monotonic() - began
        assert b"watchdog-ready\n" in received, received
        assert child_pid is not None, received
        assert saw_eof, "AudioProbe kept the inherited pipe open after its parent exited"
        # 30-second fixture should exit promptly when its 0.3-second parent dies.
        assert elapsed < 1.5, (elapsed, received)
        assert parent.wait(timeout=1) == 0
        return {"elapsedSecondsIncludingParent": elapsed, "childPID": child_pid}
    finally:
        if parent.poll() is None:
            parent.kill()
            parent.wait()
        if child_pid is not None and not saw_eof:
            try:
                os.kill(child_pid, 9)
            except ProcessLookupError:
                pass
        parent.stdout.close()
        parent.stderr.close()


if __name__ == "__main__":
    probe_path = os.path.abspath(sys.argv[1])
    print(json.dumps({
        "passed": True,
        "audioDevicesOpened": False,
        "blockedMainThreadDeadline": deadline_test(probe_path),
        "parentExit": parent_exit_test(probe_path),
    }, indent=2))
