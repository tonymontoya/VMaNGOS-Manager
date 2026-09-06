# VMaNGOS wizard smoke container.
#
# A systemd-capable Ubuntu 26.04 image for the real install smoke
# (tests/smoke/wizard_smoke.sh). systemd runs as PID 1, which makes
# `systemd-run`/`systemctl`/`journalctl` real inside the container — exactly
# what the install runner (manager/lib/installer.sh) needs.
#
# Two things are load-bearing and easy to break:
#   * Do NOT add `VOLUME ["/sys/fs/cgroup"]`. A Docker volume shadows
#     /sys/fs/cgroup with an ext4 mount and systemd will not boot (exit 255).
#   * Run with `--privileged --cgroupns=host` (see wizard_smoke.sh). With the
#     host cgroup namespace the container sees the host cgroup2 hierarchy,
#     which is writable under --privileged, so systemd can manage units.
#
FROM ubuntu:26.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        systemd systemd-sysv dbus dbus-user-session \
        ca-certificates curl python3 python3-pip python3-venv tmux make \
        sudo \
    && rm -rf /var/lib/apt/lists/*
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
