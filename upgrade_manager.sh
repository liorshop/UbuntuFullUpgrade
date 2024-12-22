# !/bin/bash

# Full Ubuntu upgrade manager - handles 20.04 -> 22.04 -> 24.04
set -euo pipefail

BASE_DIR="/update/upgrade"
LOG_FILE="${BASE_DIR}/upgrade.log"
STATE_FILE="${BASE_DIR}/.upgrade_state"
LOCK_FILE="${BASE_DIR}/.upgrade_lock"
CURRENT_TARGET=""

log() {
    local level=$1
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "${timestamp} [${level}] ${message}" | tee -a "${LOG_FILE}"
}

setup_unattended_env() {
    export DEBIAN_FRONTEND=noninteractive
    export DEBIAN_PRIORITY=critical
    export UCF_FORCE_CONFFNEW=1
    export APT_LISTCHANGES_FRONTEND=none

    # Configure dpkg to handle config files automatically
    cat > /etc/apt/apt.conf.d/local << EOF
Dpkg::Options {
   "--force-confdef";
   "--force-confnew";
}
EOF

    # Disable service restarts prompt
    sed -i 's/#$nrconf{restart} = '"'"'i'"'"';/$nrconf{restart} = '"'"'a'"'"';/g' /etc/needrestart/needrestart.conf

    # Configure unattended upgrades
    echo "unattended-upgrades unattended-upgrades/enable_auto_updates boolean true" | debconf-set-selections
}

prepare_system() {
    log "INFO" "Preparing system for upgrade"
    
    # Update current system
    apt-get update
    apt-get -y upgrade
    apt-get -y dist-upgrade
    apt-get -y autoremove
    apt-get clean

    # Install required packages
    apt-get install -y update-manager-core
}

configure_grub() {
    DEVICE=$(grub-probe --target=device /)
    echo "grub-pc grub-pc/install_devices multiselect $DEVICE" | debconf-set-selections
}

perform_upgrade() {
    local target_version=$1
    log "INFO" "Starting upgrade to Ubuntu ${target_version}"
    
    # Configure release upgrades
    sed -i 's/Prompt=.*/Prompt=lts/' /etc/update-manager/release-upgrades
    
    # Start upgrade
    do-release-upgrade -f DistUpgradeViewNonInteractive -m server
    
    # Verify upgrade
    if [[ $(lsb_release -rs) == "${target_version}" ]]; then
        log "INFO" "Successfully upgraded to ${target_version}"
        return 0
    else
        log "ERROR" "Upgrade to ${target_version} failed"
        return 1
    fi
}

save_state() {
    echo "${CURRENT_TARGET}" > "${STATE_FILE}"
}

get_state() {
    if [ -f "${STATE_FILE}" ]; then
        cat "${STATE_FILE}"
    else
        echo "initial"
    fi
}

setup_next_boot() {
    # Create systemd service
    cat > /etc/systemd/system/ubuntu-full-upgrade.service << EOF
[Unit]
Description=Ubuntu Full Upgrade Process
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash ${BASE_DIR}/upgrade_manager.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl enable ubuntu-full-upgrade.service
}

cleanup() {
    apt-get -y dist-upgrade
    apt-get -y autoremove
    apt-get clean
    
    # Disable the upgrade service
    systemctl disable ubuntu-full-upgrade.service
    rm -f /etc/systemd/system/ubuntu-full-upgrade.service
    
    # Remove state files
    rm -f "${STATE_FILE}" "${LOCK_FILE}"
}

main() {
    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        echo "This script must be run as root" >&2
        exit 1
    }

    # Create necessary directories
    mkdir -p "${BASE_DIR}"
    
    # Get current state
    CURRENT_TARGET=$(get_state)
    
    # Setup unattended environment
    setup_unattended_env
    
    case "${CURRENT_TARGET}" in
        "initial")
            log "INFO" "Starting initial upgrade process"
            prepare_system
            configure_grub
            CURRENT_TARGET="22.04"
            save_state
            setup_next_boot
            log "INFO" "System prepared for 22.04 upgrade. Rebooting..."
            shutdown -r +1 "Rebooting for upgrade to 22.04"
            ;;
            
        "22.04")
            log "INFO" "Continuing with 22.04 upgrade"
            if perform_upgrade "22.04"; then
                CURRENT_TARGET="24.04"
                save_state
                log "INFO" "Upgrade to 22.04 complete. Rebooting..."
                shutdown -r +1 "Rebooting after 22.04 upgrade"
            else
                log "ERROR" "Failed to upgrade to 22.04"
                exit 1
            fi
            ;;
            
        "24.04")
            log "INFO" "Starting 24.04 upgrade"
            # Wait for system stability and package updates
            sleep 300
            prepare_system
            if perform_upgrade "24.04"; then
                log "INFO" "Successfully upgraded to 24.04"
                cleanup
                log "INFO" "Upgrade process complete. Final reboot..."
                shutdown -r +1 "Final reboot after completing upgrade to 24.04"
            else
                log "ERROR" "Failed to upgrade to 24.04"
                exit 1
            fi
            ;;
            
        *)
            log "ERROR" "Unknown upgrade state: ${CURRENT_TARGET}"
            exit 1
            ;;
    esac
}

main "$@"