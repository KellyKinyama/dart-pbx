#!/bin/bash
# Ensures Asterisk-owned directories exist and are writable, then hands
# off (`exec`) to the real Asterisk binary so the container's PID 1 is
# Asterisk (and signals propagate).

set -e

# Make sure every directory Asterisk writes to actually exists. Some
# images (andrius/asterisk:stable) ship without /var/log/asterisk/cdr-csv,
# /var/spool/asterisk/voicemail, etc., which causes runtime warnings.
mkdir -p \
  /etc/asterisk \
  /var/lib/asterisk \
  /var/lib/asterisk/sounds \
  /var/lib/asterisk/static-http \
  /var/lib/asterisk/ssl \
  /var/log/asterisk \
  /var/log/asterisk/cdr-csv \
  /var/log/asterisk/cdr-custom \
  /var/spool/asterisk \
  /var/spool/asterisk/voicemail \
  /var/spool/asterisk/monitor \
  /var/spool/asterisk/recording \
  /var/spool/asterisk/tmp \
  /var/run/asterisk

chown -R asterisk:asterisk \
  /etc/asterisk \
  /var/lib/asterisk \
  /var/log/asterisk \
  /var/spool/asterisk \
  /var/run/asterisk 2>/dev/null || true

chmod -R u+rwX,g+rwX /var/log/asterisk /var/spool/asterisk /var/run/asterisk
chmod -R u+rwX /var/lib/asterisk/static-http /var/lib/asterisk/ssl 2>/dev/null || true

exec /usr/sbin/asterisk -fvvvdddT
