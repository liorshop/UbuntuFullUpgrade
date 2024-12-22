#!/bin/bash

# Pre-upgrade cleanup script
set -euo pipefail

BASE_DIR="/update/upgrade"
LOG_FILE="${BASE_DIR}/upgrade.log"

log() {
    local level=$1
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "${timestamp} [${level}] ${message}" | tee -a "${LOG_FILE}"
}

# Backup PostgreSQL database
backup_postgres() {
    log "INFO" "Starting PostgreSQL backup for database 'bobe'"
    
    if command -v pg_dump >/dev/null; then
        # Create backup directory if it doesn't exist
        mkdir -p "${BASE_DIR}/backups"
        
        # Set backup filename with timestamp
        BACKUP_FILE="${BASE_DIR}/backups/bobe_$(date +%Y%m%d_%H%M%S).sql"
        
        # Attempt database dump
        if sudo -u postgres pg_dump bobe > "${BACKUP_FILE}"; then
            log "INFO" "PostgreSQL backup completed successfully: ${BACKUP_FILE}"
            # Create a compressed copy
            gzip -c "${BACKUP_FILE}" > "${BACKUP_FILE}.gz"
            log "INFO" "Compressed backup created: ${BACKUP_FILE}.gz"
        else
            log "ERROR" "PostgreSQL backup failed"
            exit 1
        fi
    else
        log "WARN" "pg_dump not found - PostgreSQL might not be installed"
    fi
}

# Remove specified packages and their configurations
cleanup_packages() {
    log "INFO" "Starting package cleanup"
    
    # Stop services first
    services=("postgresql" "mongod" "monit")
    for service in "${services[@]}"; do
        if systemctl is-active --quiet ${service}; then
            log "INFO" "Stopping ${service} service"
            systemctl stop ${service}
        fi
    done
    
    # Create list of packages to remove
    packages=(
        "postgresql*"
        "monit*"
        "mongodb*"
        "mongo-tools"
        "openjdk*"
    )
    
    # Purge packages
    for pkg in "${packages[@]}"; do
        log "INFO" "Purging packages matching: ${pkg}"
        apt-get purge -y ${pkg} || log "WARN" "Some packages matching ${pkg} could not be purged"
    done
    
    # Remove dependencies that are no longer needed
    log "INFO" "Removing unused dependencies"
    apt-get autoremove -y
    
    # Clean apt cache
    apt-get clean
}

# Remove third-party source lists
cleanup_sources() {
    log "INFO" "Cleaning up package sources"
    
    # Remove third-party source lists for specified packages
    sources=(
        "postgresql"
        "mongodb"
        "openjdk"
    )
    
    for source in "${sources[@]}"; do
        # Remove from sources.list
        if [ -f "/etc/apt/sources.list" ]; then
            sed -i "/${source}/d" /etc/apt/sources.list
        fi
        
        # Remove source list files
        rm -f /etc/apt/sources.list.d/*${source}*
    done
    
    # Remove downloaded lists
    rm -f /var/lib/apt/lists/*postgresql*
    rm -f /var/lib/apt/lists/*mongodb*
    rm -f /var/lib/apt/lists/*openjdk*
    
    # Update package lists after cleaning
    apt-get update
}

# Main execution
main() {
    log "INFO" "Starting pre-upgrade cleanup process"
    
    # Ensure running as root
    if [[ $EUID -ne 0 ]]; then
        echo "This script must be run as root" >&2
        exit 1
    }
    
    # Create necessary directories
    mkdir -p "${BASE_DIR}"
    
    # Execute cleanup steps
    backup_postgres
    cleanup_packages
    cleanup_sources
    
    log "INFO" "Pre-upgrade cleanup completed successfully"
}

main "$@"