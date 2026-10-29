# fish counterpart of the base's /etc/profile.d/caffeinate.sh (from
# projectbluefin/common), which only bash reads. Shipped by
# dakota-nvidia-580; autoloaded from vendor_functions.d.
function caffeinate --description 'Prevent the system from sleeping, like macOS caffeinate'
    # Usage: caffeinate              — hold indefinitely (Ctrl+C to release)
    #        caffeinate sleep 3600   — hold while command runs
    if test (count $argv) -eq 0
        echo "Preventing system sleep. Press Ctrl+C to allow sleep again."
        systemd-inhibit \
            --what=idle:sleep:handle-lid-switch \
            --who=caffeinate \
            --why="User requested no sleep" \
            --mode=block \
            sleep infinity
    else
        systemd-inhibit \
            --what=idle:sleep:handle-lid-switch \
            --who=caffeinate \
            --why="Running: $argv" \
            --mode=block \
            $argv
    end
end
