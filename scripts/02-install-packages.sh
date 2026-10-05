#!/bin/bash
# 02-install-packages.sh
#
# Description:
#   Installs userspace tools needed to format a LUKS2 dump target and
#   analyze a vmcore. cryptsetup 2.7+ is required for
#   --link-vk-to-keyring / --volume-key-keyring. crash is optional for
#   post-dump analysis but listed in the guest test plan.
#
# When to run:
#   After 01-verify-prereqs.sh if cryptsetup or crash is missing.
#
# Usage:
#   ./02-install-packages.sh
#
# Requires:
#   Network access to the distribution repositories (dnf).

set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
require_root

info "Installing cryptsetup and crash"
dnf install -y cryptsetup crash
rpm -q cryptsetup crash
cryptsetup --version

ver=$(cryptsetup --version | awk '{print $2; exit}')
info "cryptsetup version=$ver (need 2.7 or later for volume-key keyring APIs)"
