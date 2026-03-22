#!/usr/bin/env python3
"""Background ping sampler for the Ping Monitor plasmoid."""

from __future__ import annotations

import os
import re
import signal
import subprocess
import sys
import time
from pathlib import Path


STATE_PATH = Path(f"/run/user/{os.getuid()}/ping-monitor-state")
PING_FAST_S = 1.0
PING_SLOW_S = 5.0
GATEWAY_REFRESH_S = 30.0
PING_TIMEOUT_S = 1.2

PING_RE = re.compile(r"time[=<]([\d.]+)\s*ms", re.IGNORECASE)


def run_command(cmd: list[str], timeout: float = 2.0) -> str:
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
        return result.stdout
    except Exception:
        return ""


def parse_ping_ms(output: str) -> float:
    for line in reversed(output.splitlines()):
        match = PING_RE.search(line)
        if match:
            try:
                return float(match.group(1))
            except ValueError:
                return -1.0
        lower = line.lower()
        if (
            "timeout" in lower
            or "unreachable" in lower
            or "100% packet loss" in lower
            or "no answer yet" in lower
        ):
            return -1.0
    return -1.0


def get_gateway_ip() -> str:
    output = run_command(["ip", "route", "show", "default"], timeout=1.0)
    for line in output.splitlines():
        parts = line.split()
        if len(parts) >= 3 and parts[0] == "default" and parts[1] == "via":
            return parts[2]
    return ""


def state_lines(state: dict[str, object]) -> list[str]:
    keys = [
        "timestamp",
        "gateway_ip",
        "cloudflare_ping",
        "cloudflare_seq",
        "google_ping",
        "google_seq",
        "gateway_ping",
        "gateway_seq",
        "poll_interval_ms",
        "consecutive_failure_cycles",
    ]
    return [f"{key}={state[key]}" for key in keys]


def write_state(state: dict[str, object]) -> None:
    STATE_PATH.parent.mkdir(parents=True, exist_ok=True)
    tmp = STATE_PATH.with_name(STATE_PATH.name + ".tmp")
    tmp.write_text("\n".join(state_lines(state)) + "\n", encoding="utf-8")
    tmp.replace(STATE_PATH)


class PingMonitorDaemon:
    def __init__(self) -> None:
        self.running = True
        self.state: dict[str, object] = {
            "timestamp": int(time.time()),
            "gateway_ip": "",
            "cloudflare_ping": -1.0,
            "cloudflare_seq": 0,
            "google_ping": -1.0,
            "google_seq": 0,
            "gateway_ping": -1.0,
            "gateway_seq": 0,
            "poll_interval_ms": int(PING_FAST_S * 1000),
            "consecutive_failure_cycles": 0,
        }
        self.next_gateway_refresh = 0.0

    def stop(self, *_args) -> None:
        self.running = False

    def refresh_gateway(self, now: float) -> None:
        if now < self.next_gateway_refresh:
            return
        self.next_gateway_refresh = now + GATEWAY_REFRESH_S
        new_ip = get_gateway_ip()
        if new_ip == self.state["gateway_ip"]:
            return
        self.state["gateway_ip"] = new_ip
        self.state["gateway_ping"] = -1.0
        self.state["gateway_seq"] = int(self.state["gateway_seq"]) + 1

    def sample_targets(self) -> int:
        commands: dict[str, list[str] | None] = {
            "cloudflare": ["ping", "-n", "-c", "1", "-W", "1", "1.1.1.1"],
            "google": ["ping", "-n", "-c", "1", "-W", "1", "8.8.8.8"],
            "gateway": None,
        }
        gateway_ip = str(self.state["gateway_ip"])
        if gateway_ip:
            commands["gateway"] = ["ping", "-n", "-c", "1", "-W", "1", gateway_ip]

        processes: dict[str, subprocess.Popen[str]] = {}
        for target, cmd in commands.items():
            if cmd is None:
                continue
            try:
                processes[target] = subprocess.Popen(
                    cmd,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    text=True,
                )
            except Exception:
                pass

        successes = 0
        for target in ("cloudflare", "google", "gateway"):
            seq_key = f"{target}_seq"
            ping_key = f"{target}_ping"
            self.state[seq_key] = int(self.state[seq_key]) + 1

            proc = processes.get(target)
            if proc is None:
                self.state[ping_key] = -1.0
                continue

            try:
                stdout, _ = proc.communicate(timeout=PING_TIMEOUT_S)
            except subprocess.TimeoutExpired:
                proc.kill()
                try:
                    stdout, _ = proc.communicate(timeout=0.2)
                except Exception:
                    stdout = ""
            except Exception:
                stdout = ""

            ping_ms = parse_ping_ms(stdout)
            self.state[ping_key] = ping_ms
            if ping_ms >= 0:
                successes += 1

        return successes

    def complete_cycle(self, successes: int) -> None:
        if successes == 0:
            self.state["consecutive_failure_cycles"] = int(self.state["consecutive_failure_cycles"]) + 1
        else:
            self.state["consecutive_failure_cycles"] = 0

        if int(self.state["consecutive_failure_cycles"]) >= 3:
            self.state["poll_interval_ms"] = int(PING_SLOW_S * 1000)
        else:
            self.state["poll_interval_ms"] = int(PING_FAST_S * 1000)

    def run(self) -> None:
        signal.signal(signal.SIGINT, self.stop)
        signal.signal(signal.SIGTERM, self.stop)
        while self.running:
            loop_start = time.monotonic()
            now = time.time()
            self.refresh_gateway(loop_start)
            successes = self.sample_targets()
            self.state["timestamp"] = int(now)
            self.complete_cycle(successes)

            write_state(self.state)
            interval = int(self.state["poll_interval_ms"]) / 1000.0
            elapsed = time.monotonic() - loop_start
            time.sleep(max(0.05, interval - elapsed))


def main() -> int:
    PingMonitorDaemon().run()
    return 0


if __name__ == "__main__":
    sys.exit(main())
