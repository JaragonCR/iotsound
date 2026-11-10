#!/usr/bin/env python3
"""
WiFi Watchdog Service for IoTSound
Monitors WiFi connectivity and audio playback.
Implements recovery logic: WiFi toggle → reboot if needed.
"""

import json
import os
import subprocess
import time
import logging
import urllib.request
from pathlib import Path


def _env_int(name: str, default: int) -> int:
    try:
        return int(os.environ.get(name, str(default)))
    except (TypeError, ValueError):
        return default


# Configuration (honors environment variables exported by start.sh / Balena)
WIFI_CHECK_INTERVAL = _env_int("WIFI_CHECK_INTERVAL", 30)        # Check every 30 seconds
WIFI_OFFLINE_THRESHOLD = _env_int("WIFI_OFFLINE_THRESHOLD", 600) # 10 minutes
WIFI_RECOVERY_WAIT = _env_int("WIFI_RECOVERY_WAIT", 300)         # 5 minutes between attempts
MAX_RECOVERY_ATTEMPTS = _env_int("MAX_RECOVERY_ATTEMPTS", 3)
AUDIO_CHECK_INTERVAL = _env_int("AUDIO_CHECK_INTERVAL", 60)      # Check if audio is playing
SUPERVISOR_PORT = _env_int("SOUND_SUPERVISOR_PORT", 80)
INPUT_SINK = os.environ.get("SOUND_INPUT_SINK", "balena-sound.input")

LOG_FILE = "/tmp/wifi-watchdog.log"
STATE_FILE = "/tmp/wifi-watchdog-state.txt"

# Setup logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler(LOG_FILE),
        logging.StreamHandler()
    ]
)
logger = logging.getLogger(__name__)


class WiFiWatchdog:
    def __init__(self):
        self.offline_start_time = None
        self.recovery_attempts = 0
        self.last_audio_check = 0
        self.audio_playing = False
        logger.info(
            "WiFi Watchdog initialized (check=%ss, threshold=%ss, wait=%ss, max_attempts=%s)",
            WIFI_CHECK_INTERVAL,
            WIFI_OFFLINE_THRESHOLD,
            WIFI_RECOVERY_WAIT,
            MAX_RECOVERY_ATTEMPTS,
        )

    def _has_wired_connection(self) -> bool:
        """Return True if an Ethernet interface has an active IPv4 address."""
        try:
            result = subprocess.run(
                ["ip", "-4", "-o", "addr", "show", "scope", "global"],
                capture_output=True,
                text=True,
                timeout=5
            )
            for line in result.stdout.splitlines():
                parts = line.split()
                if len(parts) >= 2 and (parts[1].startswith("eth") or parts[1].startswith("en")):
                    return True
        except Exception:
            pass
        return False

    def _get_default_gateway(self) -> str:
        """Return the default IPv4 gateway address, or empty string if none."""
        try:
            result = subprocess.run(
                ["ip", "-4", "route", "show", "default"],
                capture_output=True,
                text=True,
                timeout=5
            )
            for line in result.stdout.splitlines():
                parts = line.split()
                if "via" in parts:
                    idx = parts.index("via")
                    if idx + 1 < len(parts):
                        return parts[idx + 1]
        except Exception:
            pass
        return ""

    def is_wifi_connected(self):
        """Check if network/WiFi is connected using multiple methods."""
        try:
            # Do not toggle WiFi or reboot if the device is connected via Ethernet
            # or does not have a wlan0 interface at all.
            if self._has_wired_connection():
                return True
            if not Path("/sys/class/net/wlan0").exists():
                return True

            # Method 1: Check iwconfig on wlan0 for SSID
            result = subprocess.run(
                ["iwconfig", "wlan0"],
                capture_output=True,
                text=True,
                timeout=5
            )
            if "ESSID:off" in result.stdout or 'ESSID:""' in result.stdout:
                return False

            # Method 2: Ping default gateway first (works on isolated/offline LANs),
            # falling back to public DNS if the gateway drops ICMP.
            targets = []
            gw = self._get_default_gateway()
            if gw:
                targets.append(gw)
            targets.append("8.8.8.8")

            for target in targets:
                ping_res = subprocess.run(
                    ["ping", "-c", "1", "-W", "2", target],
                    capture_output=True,
                    timeout=5
                )
                if ping_res.returncode == 0:
                    return True
            return False
        except Exception as e:
            logger.error(f"Error checking WiFi connection: {e}")
            return False

    def is_audio_playing(self):
        """True only while a local source is actually playing.

        Asks sound-supervisor for the sink list and checks whether the plugin input sink
        (balena-sound.input) is RUNNING. The previous check looked for processes such as
        shairport-sync, which run permanently as daemons, so it was always true and recovery
        never ran. The hardware sink is no use either: a loopback keeps it RUNNING when idle.
        If the supervisor cannot be reached we report False so recovery is not blocked.
        """
        try:
            with urllib.request.urlopen(
                f"http://localhost:{SUPERVISOR_PORT}/audio/sinks", timeout=5
            ) as resp:
                sinks = json.loads(resp.read().decode("utf-8"))
            for sink in sinks:
                if sink.get("name") == INPUT_SINK:
                    return str(sink.get("state", "")).upper() == "RUNNING"
            return False
        except Exception as e:
            logger.warning(f"Error checking audio status: {e}")
            return False

    def toggle_wifi(self):
        """Toggle WiFi off and on."""
        try:
            logger.info("Toggling WiFi off...")
            subprocess.run(
                ["ip", "link", "set", "wlan0", "down"],
                timeout=10,
                check=True
            )
            time.sleep(5)

            logger.info("Toggling WiFi on...")
            subprocess.run(
                ["ip", "link", "set", "wlan0", "up"],
                timeout=10,
                check=True
            )
            return True
        except Exception as e:
            logger.error(f"Error toggling WiFi: {e}")
            return False

    def reboot_device(self):
        """Reboot the device via sound-supervisor / Balena Supervisor API, falling back to shutdown."""
        logger.critical("Initiating device reboot after WiFi recovery failed")
        try:
            req = urllib.request.Request(
                f"http://localhost:{SUPERVISOR_PORT}/device/reboot",
                data=b"{}",
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            with urllib.request.urlopen(req, timeout=5) as resp:
                if 200 <= resp.status < 300:
                    return
        except Exception as e:
            logger.warning(f"Supervisor reboot endpoint failed ({e}), falling back to shutdown -r now")

        try:
            subprocess.run(["shutdown", "-r", "now"], timeout=5)
        except Exception as e:
            logger.error(f"Error rebooting device: {e}")

    def save_state(self):
        """Save state to file for monitoring/debugging."""
        try:
            with open(STATE_FILE, 'w') as f:
                f.write(f"offline_start_time={self.offline_start_time}\n")
                f.write(f"recovery_attempts={self.recovery_attempts}\n")
                f.write(f"audio_playing={self.audio_playing}\n")
        except Exception as e:
            logger.warning(f"Error saving state: {e}")

    def reset_state(self):
        """Reset recovery state when WiFi comes back online."""
        logger.info("WiFi restored! Resetting recovery counter")
        self.offline_start_time = None
        self.recovery_attempts = 0
        self.save_state()

    def run(self):
        """Main watchdog loop."""
        logger.info("Starting WiFi watchdog loop")

        while True:
            try:
                current_time = time.time()
                is_connected = self.is_wifi_connected()

                # Check audio status periodically
                if current_time - self.last_audio_check >= AUDIO_CHECK_INTERVAL:
                    self.audio_playing = self.is_audio_playing()
                    self.last_audio_check = current_time

                if is_connected:
                    if self.offline_start_time is not None:
                        self.reset_state()
                else:
                    # WiFi is offline
                    if self.offline_start_time is None:
                        self.offline_start_time = current_time
                        logger.warning("WiFi connection lost")

                    offline_duration = current_time - self.offline_start_time

                    # Only take action if offline for threshold AND no audio playing
                    if offline_duration >= WIFI_OFFLINE_THRESHOLD and not self.audio_playing:
                        logger.warning(
                            f"WiFi offline for {offline_duration:.0f}s (threshold: {WIFI_OFFLINE_THRESHOLD}s), "
                            f"audio playing: {self.audio_playing}, "
                            f"attempting recovery ({self.recovery_attempts}/{MAX_RECOVERY_ATTEMPTS})"
                        )

                        if self.recovery_attempts < MAX_RECOVERY_ATTEMPTS:
                            self.recovery_attempts += 1
                            self.save_state()

                            if self.toggle_wifi():
                                logger.info(f"WiFi toggle attempt {self.recovery_attempts} completed")
                                time.sleep(WIFI_RECOVERY_WAIT)
                            else:
                                logger.error("WiFi toggle failed")
                        else:
                            logger.critical("Max recovery attempts exceeded, rebooting device")
                            self.reboot_device()

                self.save_state()
                time.sleep(WIFI_CHECK_INTERVAL)

            except KeyboardInterrupt:
                logger.info("WiFi watchdog stopped by user")
                break
            except Exception as e:
                logger.error(f"Unexpected error in main loop: {e}")
                time.sleep(WIFI_CHECK_INTERVAL)


if __name__ == "__main__":
    watchdog = WiFiWatchdog()
    watchdog.run()
