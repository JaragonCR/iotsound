
#!/bin/bash

set -e

# IMPORTANT: You need to create a lircd.conf file for your remote.
# You can generate it using 'irrecord' on your device.
# Once generated, copy it to /etc/lirc/lircd.conf in this container.
# For example, you can add a 'COPY lircd.conf /etc/lirc/lircd.conf' line to the Dockerfile.template.

# Start the LIRC daemon, assuming the USB IR receiver is at /dev/lirc0
lircd --device /dev/lirc0

# Start irexec to translate IR commands to shell commands
irexec -d
