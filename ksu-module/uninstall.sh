#!/system/bin/sh

if grep -q '^nohello ' /proc/modules 2>/dev/null; then
	rmmod nohello 2>/dev/null
fi

