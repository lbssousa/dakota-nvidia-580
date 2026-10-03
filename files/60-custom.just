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
