# Toggle between stock ("pure") GNOME and Bluefin's GNOME customizations.
#
# Bluefin bakes its desktop defaults into GSettings default-value overrides
# (/usr/share/glib-2.0/schemas/zz*-bluefin-*.gschema.override), compiled into
# the system gschemas.compiled, so they can't be switched off at runtime
# system-wide. Instead this recipe works per user, through dconf:
#   - pure:    for every key those override files set, write the stock
#              default (read from a scratch schema cache compiled WITHOUT any
#              override) into the user's dconf;
#   - bluefin: reset those keys, so Bluefin's baked-in defaults show through.
# Wallpapers (org.gnome.desktop.background / screensaver) are never touched.
# Relocatable schemas (e.g. Ptyxis, custom keybindings) can't be handled by
# gsettings without a path and are skipped.
#
# NOTE: both directions overwrite the user's own values for those keys.

[group('Customization')]
gnome-pure-toggle ACTION="toggle":
    #!/usr/bin/bash
    set -euo pipefail

    action="{{ ACTION }}"
    state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/dakota-nvidia-580"
    marker="$state_dir/gnome-pure"
    skip_schemas="org.gnome.desktop.background org.gnome.desktop.screensaver"

    if [ "$action" = "toggle" ]; then
        if [ -e "$marker" ]; then action="bluefin"; else action="pure"; fi
    fi
    case "$action" in pure|bluefin) ;; *)
        echo "Usage: ujust gnome-pure-toggle [pure|bluefin|toggle]" >&2; exit 2 ;;
    esac

    # "schema key" pairs set by Bluefin's override files, minus wallpapers.
    mapfile -t keys < <(
        awk '
            /^[[:space:]]*(#|$)/ { next }
            /^\[.*\]/ { gsub(/[\[\] \t]/, ""); schema = $0; next }
            schema != "" && /=/ { split($0, kv, "="); gsub(/[ \t]/, "", kv[1]); print schema, kv[1] }
        ' /usr/share/glib-2.0/schemas/zz*-bluefin-*.gschema.override \
        | sort -u \
        | while read -r schema key; do
            case " $skip_schemas " in *" $schema "*) continue ;; esac
            echo "$schema $key"
        done
    )

    # Scratch schema dir with the stock schemas only (no overrides).
    clean="$(mktemp -d)"
    trap 'rm -rf "$clean"' EXIT
    cp /usr/share/glib-2.0/schemas/*.xml "$clean"/ 2>/dev/null || true
    cp /usr/share/gnome-shell/extensions/*/schemas/*.gschema.xml "$clean"/ 2>/dev/null || true
    glib-compile-schemas "$clean"

    changed=0
    for pair in "${keys[@]}"; do
        read -r schema key <<<"$pair"
        if [ "$action" = "pure" ]; then
            value="$(GSETTINGS_BACKEND=memory GSETTINGS_SCHEMA_DIR="$clean" gsettings get "$schema" "$key" 2>/dev/null)" || continue
            GSETTINGS_SCHEMA_DIR="$clean" gsettings set "$schema" "$key" "$value" 2>/dev/null || continue
        else
            GSETTINGS_SCHEMA_DIR="$clean" gsettings reset "$schema" "$key" 2>/dev/null || continue
        fi
        changed=$((changed + 1))
    done

    mkdir -p "$state_dir"
    if [ "$action" = "pure" ]; then touch "$marker"; else rm -f "$marker"; fi
    echo "Switched to $action GNOME ($changed settings updated; wallpapers untouched)."

# Needed even with Secure Boot off: Dakota's lockdown=integrity refuses the
# NVIDIA modules until this image's key is enrolled as a MOK (see README.md,
# "Secure Boot and module signing").
#
# Set up Secure Boot: Dakota's shim chain and key, plus this image's NVIDIA key
[group('System')]
enroll-nvidia-secure-boot-key:
    #!/usr/bin/bash
    set -euo pipefail
    cert=/usr/lib/dakota-nvidia-580/secure-boot/module-signing.der
    if [ ! -t 0 ]; then
        echo "Interactive terminal required" >&2
        exit 1
    fi
    echo "Step 1/2: Dakota's Secure Boot setup (shim, boot entry, Dakota's key)."
    echo
    # Also queues Dakota's key: one MokManager visit enrolls both.
    sudo /usr/libexec/dakota-secure-boot enroll
    echo
    echo "Step 2/2: this image's NVIDIA module signing key."
    if [[ $(mokutil --ignore-keyring --test-key "$cert" 2>&1 || true) == *"already enrolled"* ]]; then
        echo "Already enrolled."
        exit 0
    fi
    # Same password dakota-secure-boot uses, so the one MokManager prompt
    # covers both keys.
    printf 'dakota\ndakota\n' | sudo mokutil --ignore-keyring --import "$cert"
    sudo mokutil --timeout -1
    echo "Queued. Reboot, choose \"Enroll MOK\" in MokManager, check that it lists"
    echo "BOTH keys (Dakota's and \"dakota-nvidia-580 module signing key\"),"
    echo "then \"Continue\", \"Yes\", password \"dakota\", \"Reboot\"."

# Show whether the NVIDIA modules can load under Dakota's lockdown
[group('System')]
nvidia-secure-boot-status:
    #!/usr/bin/bash
    set -uo pipefail
    cert=/usr/lib/dakota-nvidia-580/secure-boot/module-signing.der
    cn="$(openssl x509 -inform DER -in "$cert" -noout -subject -nameopt multiline | sed -n 's/^ *commonName *= *//p')"
    echo "Secure Boot:      $(mokutil --sb-state 2>/dev/null | head -n1)"
    echo "Kernel lockdown:  $(cat /sys/kernel/security/lockdown 2>/dev/null || echo unavailable)"
    test="$(mokutil --ignore-keyring --test-key "$cert" 2>&1 || true)"
    if [[ $test == *"already enrolled"* ]]; then
        echo "NVIDIA key MOK:   enrolled"
    elif [[ -n $(mokutil --list-new 2>/dev/null) ]]; then
        echo "NVIDIA key MOK:   maybe pending — confirm in MokManager on the next boot"
    else
        echo "NVIDIA key MOK:   not enrolled — run 'ujust enroll-nvidia-secure-boot-key'"
    fi
    # The kernel trusts MOKs for modules only when shim exports
    # MokListTrustedRT (the default since shim 15.6); otherwise the key
    # lands in .platform, not .machine, and modules are still refused.
    if journalctl -k -b 2>/dev/null | grep -q "Loaded X.509 cert '.*${cn}"; then
        echo "Kernel keyring:   key loaded at boot"
    else
        echo "Kernel keyring:   key not loaded this boot (not enrolled yet, booted without shim,"
        echo "                  or MOK trust off — 'sudo mokutil --trust-mok' and reboot)"
    fi
    if [ -d /sys/module/nvidia ]; then
        echo "nvidia module:    loaded ($(cat /sys/module/nvidia/version 2>/dev/null))"
    else
        echo "nvidia module:    NOT loaded — see 'journalctl -k -b | grep -i -e nvidia -e lockdown'"
    fi
