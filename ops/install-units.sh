#!/usr/bin/env bash
# ops/install-units.sh — render ops/systemd/*.in for THIS project and install them, user scope.
# (feat_harness_ops_alerts_are_conditions_with_one_email_on_failing_and_one_on_recovery)
#
#   bash ops/install-units.sh            # render + install + enable the timers (systemctl --user)
#   bash ops/install-units.sh --render   # render only, to ./.agent/units/ — nothing installed
#   bash ops/install-units.sh --self-test
#
# A template carries @@PROJECT@@ (HARNESS_PROJECT) and @@REPO_ROOT@@; the installed unit is named
# <project>-<template name>. The OnFailure hook <project>-unit-failure@.service turns any unit's failure
# into a CONDITION (ops/ops-alert-unit-failure.sh): one email when it fails, one when the settle
# tick finds it healthy again. ⚠ Edit the template and re-run this; never the installed copy.
# ⚠ Never check a unit with `systemd-analyze --user verify` on a machine whose user manager is running: it
# starts a throwaway manager that replaces $XDG_RUNTIME_DIR/systemd/private, and every `systemctl --user`
# then fails ("Failed to connect to bus") until the user manager restarts. `--render` and a read are enough.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
. "$HERE/../scripts/lib/selftest-flag.sh"
. "$HERE/../scripts/lib/harness-env.sh"

# render_unit <template> <project> <repo root> -> the unit text on stdout   (pure)
render_unit() { sed -e "s|@@PROJECT@@|$2|g" -e "s|@@REPO_ROOT@@|$3|g" "$1"; }
# installed_name <template path> <project> -> <project>-<basename without .in>
installed_name() { local b; b="$(basename -- "$1" .in)"; printf '%s-%s\n' "$2" "$b"; }

selftest_reject_typo "${1:-}"
if selftest_is_flag "${1:-}"; then
  f=0; d="$(mktemp -d)"; _t() { [[ "$2" == "$3" ]] && printf '  ok    %s\n' "$1" || { printf '  FAIL  %s (want %q got %q)\n' "$1" "$2" "$3"; f=1; }; }
  printf '[Unit]\nDescription=@@PROJECT@@ x\nOnFailure=@@PROJECT@@-unit-failure@%%n.service\n[Service]\nWorkingDirectory=@@REPO_ROOT@@\n' > "$d/t.service.in"
  _t "placeholders are rendered" "[Unit]
Description=proj x
OnFailure=proj-unit-failure@%n.service
[Service]
WorkingDirectory=/r" "$(render_unit "$d/t.service.in" proj /r)"
  _t "the installed name is <project>-<template>" "proj-t.service" "$(installed_name "$d/t.service.in" proj)"
  _t "the shipped templates leave no placeholder behind" 0 "$(for t in "$ROOT"/ops/systemd/*.in; do render_unit "$t" proj /r; done | awk '/@@/{n++} END{print n+0}')"
  _t "every shipped service template names the failure hook (the condition contract)" 0 "$(for t in "$ROOT"/ops/systemd/*.service.in; do case "$(basename "$t")" in unit-failure@*) continue;; esac; awk '/^OnFailure=@@PROJECT@@-unit-failure@%n.service/{f=1} END{exit f}' "$t" && echo "$t"; done | awk 'END{print NR}')"
  rm -rf "$d"
  (( f == 0 )) && { echo "install-units: self-test ok"; exit 0; } || { echo "install-units: self-test FAILED" >&2; exit 1; }
fi

out="$ROOT/.agent/units"; mkdir -p "$out"
for t in "$ROOT"/ops/systemd/*.in; do
  [[ -f "$t" ]] || continue
  n="$(installed_name "$t" "$HARNESS_PROJECT")"; render_unit "$t" "$HARNESS_PROJECT" "$ROOT" > "$out/$n"; echo "rendered $out/$n"
done
[[ "${1:-}" == --render ]] && exit 0
dest="$HOME/.config/systemd/user"; mkdir -p "$dest"
for u in "$out"/*; do install -m 0644 "$u" "$dest/$(basename "$u")"; echo "installed $dest/$(basename "$u")"; done
systemctl --user daemon-reload
for u in "$out"/*.timer; do systemctl --user enable --now "$(basename "$u")" && echo "enabled $(basename "$u")"; done
