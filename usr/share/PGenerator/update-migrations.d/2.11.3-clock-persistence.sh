#!/bin/sh
set -eu

# Repair service links that older release tooling could materialize as regular
# files containing the intended target, then install the hourly clock save.
root=${PG_MIGRATION_ROOT:-}
for entry in \
 /etc/rc0.d/K01fake-hwclock \
 /etc/rc0.d/K02ntp \
 /etc/rc2.d/S98ntp \
 /etc/rc3.d/S98ntp \
 /etc/rc4.d/S98ntp \
 /etc/rc5.d/S98ntp \
 /etc/rc6.d/K01fake-hwclock \
 /etc/rc6.d/K02ntp \
 /etc/rcS.d/S08fake-hwclock; do
 case "$entry" in
  *fake-hwclock) target='../init.d/fake-hwclock' ;;
  *ntp) target='../init.d/ntp' ;;
 esac
 path="$root$entry"
 mkdir -p "$(dirname "$path")"
 ln -snf "$target" "$path"
done

chmod 0755 "$root/etc/init.d/fake-hwclock" "$root/etc/init.d/ntp" "$root/etc/cron.hourly/fake-hwclock"

# The stock default restrictions include nopeer. Without a source-template
# exception, ntpd resolves pool names but refuses to mobilise associations for
# the discovered servers, so the clock never synchronises. Preserve custom
# configuration and add only the missing exception. This is intentionally in
# the migration as well as the cumulative /etc/ntp.conf overlay so 2.11.2
# units receive both halves of the clock repair when updating to 2.11.3.
ntp_conf="$root/etc/ntp.conf"
if [ -f "$ntp_conf" ] && ! grep -Eq '^[[:space:]]*restrict[[:space:]]+source([[:space:]]|$)' "$ntp_conf"; then
 printf '\n# Allow ntpd to mobilise servers discovered through pool directives.\nrestrict source nomodify notrap noquery\n' >> "$ntp_conf"
fi

system_crontab="$root/etc/crontab"
mkdir -p "$(dirname "$system_crontab")"
touch "$system_crontab"
if ! grep -qF 'run-parts /etc/cron.hourly' "$system_crontab" 2>/dev/null; then
 printf '0 * * * * root run-parts /etc/cron.hourly\n' >> "$system_crontab"
fi
chmod 0644 "$system_crontab"

# The image's system crontab already runs /etc/cron.hourly at minute zero.
# Ensure Cronie is alive after the update so the newly executable save job is
# picked up immediately; rc2.d/S90cron provides the same guarantee at boot.
if [ -z "$root" ] && ! pidof crond >/dev/null 2>&1; then
 rm -f /var/run/crond.pid
 /etc/init.d/cron start >/dev/null 2>&1 || true
fi

# The stock ntp init script relied on /var/run/ntpd.pid, which ntpd does not
# create on these images. Its restart action therefore left the old process
# alive and the new configuration unread. The cumulative overlay supplies a
# pidof-aware script; restart after extraction so the source rule takes effect
# immediately instead of waiting for the next reboot.
if [ -z "$root" ]; then
 /etc/init.d/ntp restart >/dev/null 2>&1 || true
fi
