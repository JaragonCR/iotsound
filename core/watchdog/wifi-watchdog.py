#!/usr/bin/env python3
"""
WiFi Watchdog Service for IoTSound
Monitors WiFi connectivity and audio playback.
Implements recovery logic: WiFi toggle → reboot if needed.
"""

import os
import subprocess
import time
import logging
from datetime import datetime, timedelta
from pathlib import Path

# Configuration
WIFI_CHECK_INTERVAL = 30  # Check every 30 seconds
WIFI_OFFLINE_THRESHOLD = 600  # 10 minutes
WIFI_RECOVERY_WAIT = 300  # 5 minutes between attempts
MAX_RECOVERY_ATTEMPTS = 3
AUDIO_CHECK_INTERVAL = 60  # Check if audio is playing

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
        logger.info("WiFi Watchdog initialized")

    def is_wifi_connected(self):
        """Check if WiFi is connected using multiple methods."""
        try:
            # Method 1: Check iwconfig for SSID
            result = subprocess.run(
                ["iwconfig"],
                capture_output=True,
                text=True,
                timeout=5
            )
            if "ESSID:off" in result.stdout or "ESSID:\"\"" in result.stdout:
                return False
            
            # Method 2: Try to ping gateway or public DNS
            result = subprocess.run(
                ["ping", "-c", "1", "-W", "2", "8.8.8.8"],
                capture_output=True,
                timeout=5
            )
            return result.returncode == 0
        except Exception as e:
            logger.error(f"Error checking WiFi connection: {e}")
            return False

    def is_audio_playing(self):
        """Check if audio is currently playing."""
        try:
            result = subprocess.run(
                ["pgrep", "-f", "go-librespot|shairport|snapclient|bluealsa"],
                capture_output=True,
                timeout=5
            )
            return result.returncode == 0
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
        """Reboot the device."""
        logger.critical("Initiating device reboot after WiFi recovery failed")
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
