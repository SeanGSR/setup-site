#!/bin/bash

# ============================================================
#  WEB SETUP SCRIPT v2.0
#  Manages: Static, WordPress, PHP, Reverse Proxy sites
#  Stores sites in: /home/$SUDO_USER/sites/
# ============================================================

set -o pipefail

# ── Colors & Styles ──────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
BOLD='\033[1m'
DIM='\033[2m'
UNDERLINE='\033[4m'
NC='\033[0m'

# Symbols
ARROW=">" BULLET="*" CHECK="[ok]" CROSS="[!!]" WARN="[!]"

# ── Config ───────────────────────────────────────────────────
VERSION="2.1"
SCRIPT_NAME="$(basename "$0")"
REAL_USER="${SUDO_USER:-$USER}"
SITES_ROOT="/home/${REAL_USER}/sites"
BACKUP_ROOT="/home/${REAL_USER}/backups"
BACKUP_RETENTION=7
BACKUP_REMOTE_CONF="${SITES_ROOT}/.backup-remote.conf"
LOG_FILE="/tmp/websetup.log"
LOCK_FILE="/tmp/websetup.lock"

# ── Distro Detection ────────────────────────────────────────
DISTRO_FAMILY="unknown"
WEB_USER="www-data"
NOLOGIN_SHELL="/usr/sbin/nologin"
PHP_FPM_SERVICE=""
PHP_POOL_DIR=""
NGINX_SITES="/etc/nginx/sites-available"
NGINX_ENABLED="/etc/nginx/sites-enabled"

if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    case "$ID" in
        arch|manjaro|endeavouros|artix|garuda)
            DISTRO_FAMILY="arch"
            WEB_USER="http"
            NOLOGIN_SHELL="/usr/bin/nologin"
            ;;
        debian|ubuntu|linuxmint|pop)
            DISTRO_FAMILY="debian"
            WEB_USER="www-data"
            NOLOGIN_SHELL="/usr/sbin/nologin"
            ;;
    esac
fi

# Auto-detect latest installed PHP version
if [[ "$DISTRO_FAMILY" == "arch" ]]; then
    # Arch uses unversioned PHP paths
    PHP_VERSION=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || echo "")
    PHP_FPM_SERVICE="php-fpm"
    PHP_POOL_DIR="/etc/php/php-fpm.d"
else
    # Debian uses versioned PHP directories
    PHP_VERSION=$(find /etc/php -maxdepth 1 -mindepth 1 -type d 2>/dev/null \
        | grep -oP '\d+\.\d+' | sort -V | tail -1 || true)
    PHP_VERSION="${PHP_VERSION:-8.2}"
    PHP_FPM_SERVICE="php${PHP_VERSION}-fpm"
    PHP_POOL_DIR="/etc/php/${PHP_VERSION}/fpm/pool.d"
fi

# ── Helpers ──────────────────────────────────────────────────
log() {
    local timestamp
    timestamp="$(date '+%H:%M:%S')"
    echo -e "  ${GREEN}${CHECK}${NC} ${DIM}${timestamp}${NC} $1" | tee -a "$LOG_FILE"
}

warn() {
    local timestamp
    timestamp="$(date '+%H:%M:%S')"
    echo -e "  ${YELLOW}${WARN}${NC} ${DIM}${timestamp}${NC} ${YELLOW}$1${NC}" | tee -a "$LOG_FILE"
}

error() {
    local timestamp
    timestamp="$(date '+%H:%M:%S')"
    echo -e "  ${RED}${CROSS}${NC} ${DIM}${timestamp}${NC} ${RED}${BOLD}$1${NC}" | tee -a "$LOG_FILE"
    cleanup_lock
    exit 1
}

info() {
    echo -e "  ${CYAN}${ARROW}${NC} $1"
}

# Section header
header() {
    local text="$1"
    echo
    echo -e "  ${BOLD}${BLUE}=== ${WHITE}${text} ${BLUE}===${NC}"
    echo
}

# Separator line
separator() {
    echo -e "  ${DIM}$(printf '%50s' '' | tr ' ' '-')${NC}"
}

# Confirmation prompt
confirm() {
    echo -ne "  ${YELLOW}?${NC} $1 ${DIM}[y/N]${NC} "
    read -r ans
    [[ "$ans" =~ ^[Yy]$ ]]
}

# Spinner for long operations
spinner() {
    local pid=$1
    local msg="${2:-Working...}"
    local frames=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
    local i=0
    while kill -0 "$pid" 2>/dev/null; do
        echo -ne "\r  ${MAGENTA}${frames[$i]}${NC} ${msg}"
        i=$(( (i + 1) % ${#frames[@]} ))
        sleep 0.1
    done
    wait "$pid"
    local exit_code=$?
    echo -ne "\r$(printf '%*s' 60 '')\r"
    return $exit_code
}

# ── Input Validation ─────────────────────────────────────────
validate_domain() {
    local domain="$1"
    if [[ -z "$domain" ]]; then
        error "Domain name cannot be empty."
    fi
    # Allow local TLDs (.local, .test, .localhost, .dev) and standard domains
    if ! [[ "$domain" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
        error "Invalid domain format: ${domain}. Expected something like example.com or myapp.local"
    fi
}

# Check if domain uses a local TLD
is_local_domain() {
    local domain="$1"
    [[ "$domain" =~ \.(local|test|localhost|internal)$ ]]
}

validate_port() {
    local port="$1"
    if [[ -z "$port" ]]; then
        error "Port number cannot be empty."
    fi
    if ! [[ "$port" =~ ^[0-9]+$ ]]; then
        error "Port must be a number, got: ${port}"
    fi
    if (( port < 1 || port > 65535 )); then
        error "Port must be between 1 and 65535, got: ${port}"
    fi
    if (( port < 1024 )); then
        warn "Port ${port} is a privileged port (< 1024). Make sure your app runs as root or has the right capabilities."
    fi
}

validate_email() {
    local email="$1"
    if [[ -z "$email" ]]; then
        error "Email address cannot be empty."
    fi
    if ! [[ "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        error "Invalid email format: ${email}"
    fi
}

validate_username() {
    local username="$1"
    if [[ -z "$username" ]]; then
        error "Username cannot be empty."
    fi
    if ! [[ "$username" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
        error "Invalid username: ${username}. Use lowercase letters, numbers, hyphens, underscores. Must start with a letter or underscore."
    fi
}

# ── /etc/hosts Management ────────────────────────────────────
add_to_hosts() {
    local domain="$1"
    local hosts_line="127.0.0.1   ${domain}"
    if grep -q "^127\.0\.0\.1.*${domain}" /etc/hosts 2>/dev/null; then
        log "${domain} already in /etc/hosts"
        return
    fi
    # Add under a managed comment block
    if ! grep -q "# -- websetup managed --" /etc/hosts; then
        echo -e "\n# -- websetup managed --" >> /etc/hosts
    fi
    sed -i "/# -- websetup managed --/a ${hosts_line}" /etc/hosts
    log "Added ${domain} to /etc/hosts -> 127.0.0.1"
    # Fix nsswitch.conf if using a .local domain (mDNS conflict)
    if [[ "$domain" == *.local ]]; then
        fix_nsswitch_local
    fi
}

fix_nsswitch_local() {
    local nsswitch="/etc/nsswitch.conf"
    [[ -f "$nsswitch" ]] || return 0
    local hosts_line
    hosts_line=$(grep "^hosts:" "$nsswitch" 2>/dev/null) || return 0
    # Check if mdns_minimal comes before files -- .local domains won't resolve from /etc/hosts
    if echo "$hosts_line" | grep -qP 'mdns_minimal.*\[NOTFOUND=return\].*files'; then
        warn ".local domains won't resolve: mdns_minimal blocks /etc/hosts lookups"
        info "Fixing /etc/nsswitch.conf (moving 'files' before 'mdns_minimal')..."
        sed -i 's/^\(hosts:.*\)mdns_minimal \[NOTFOUND=return\] \(.*\)files \(.*\)/\1files mdns_minimal [NOTFOUND=return] \2\3/' "$nsswitch"
        if grep "^hosts:" "$nsswitch" | grep -qP 'files.*mdns_minimal'; then
            log "Fixed nsswitch.conf: /etc/hosts now checked before mDNS"
        else
            warn "Could not auto-fix nsswitch.conf. Manually move 'files' before 'mdns_minimal' in ${nsswitch}"
        fi
    fi
}

remove_from_hosts() {
    local domain="$1"
    if grep -q "${domain}" /etc/hosts 2>/dev/null; then
        sed -i "/127\.0\.0\.1.*${domain}/d" /etc/hosts
        log "Removed ${domain} from /etc/hosts"
    fi
}

# ── Lock File ────────────────────────────────────────────────
acquire_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        local lock_pid
        lock_pid=$(cat "$LOCK_FILE" 2>/dev/null)
        if kill -0 "$lock_pid" 2>/dev/null; then
            error "Another instance is running (PID: ${lock_pid}). If this is wrong, remove ${LOCK_FILE}"
        else
            warn "Stale lock file found (PID ${lock_pid} not running). Removing."
            rm -f "$LOCK_FILE"
        fi
    fi
    echo $$ > "$LOCK_FILE"
}

cleanup_lock() {
    rm -f "$LOCK_FILE" 2>/dev/null || true
}

# ── Trap Handlers ────────────────────────────────────────────
cleanup() {
    local exit_code=$?
    cleanup_lock
    if [[ $exit_code -ne 0 ]] && [[ $exit_code -ne 130 ]]; then
        echo
        warn "Script exited with code ${exit_code}. Check log: ${LOG_FILE}"
    fi
    exit $exit_code
}

trap cleanup EXIT
trap 'echo; warn "Interrupted by user."; exit 130' INT TERM

# ── Pre-flight Checks ───────────────────────────────────────
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "\n  ${RED}${CROSS} This script must be run as root.${NC}"
        echo -e "  ${DIM}Usage: sudo ${SCRIPT_NAME}${NC}\n"
        exit 1
    fi
    if [[ -z "$REAL_USER" ]] || [[ "$REAL_USER" == "root" ]]; then
        echo -e "\n  ${RED}${CROSS} Cannot determine the real user.${NC}"
        echo -e "  ${DIM}Run with: sudo ${SCRIPT_NAME} (not as direct root login)${NC}\n"
        exit 1
    fi
}

check_os() {
    if [[ ! -f /etc/os-release ]]; then
        warn "Cannot detect OS. This script supports Debian/Ubuntu and Arch-based systems."
        confirm "Continue anyway?" || exit 0
    elif [[ "$DISTRO_FAMILY" == "unknown" ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        warn "Detected OS: ${PRETTY_NAME}. This script supports Debian/Ubuntu and Arch-based systems."
        confirm "Continue anyway?" || exit 0
    else
        # shellcheck disable=SC1091
        source /etc/os-release
        log "Detected OS: ${PRETTY_NAME} (${DISTRO_FAMILY})"
    fi
}

# ── Nginx sites-available/sites-enabled setup ───────────────
setup_nginx_dirs() {
    # Arch doesn't ship with sites-available/sites-enabled by default
    if [[ ! -d "$NGINX_SITES" ]]; then
        mkdir -p "$NGINX_SITES"
        log "Created ${NGINX_SITES}"
    fi
    if [[ ! -d "$NGINX_ENABLED" ]]; then
        mkdir -p "$NGINX_ENABLED"
        log "Created ${NGINX_ENABLED}"
    fi

    # Ensure nginx.conf includes sites-enabled
    if [[ -f /etc/nginx/nginx.conf ]]; then
        if ! grep -q "include.*sites-enabled" /etc/nginx/nginx.conf; then
            # Add include directive inside the http block
            if grep -q "^http {" /etc/nginx/nginx.conf; then
                sed -i '/^http {/a\    include /etc/nginx/sites-enabled/*;' /etc/nginx/nginx.conf
                log "Added sites-enabled include to nginx.conf"
            else
                # Try to add before the closing brace of http block
                sed -i '/^}/i\    include /etc/nginx/sites-enabled/*;' /etc/nginx/nginx.conf
                log "Added sites-enabled include to nginx.conf"
            fi
        fi
    fi
}

# ── Package Manager Abstraction ─────────────────────────────
pkg_update() {
    case "$DISTRO_FAMILY" in
        debian)
            apt update -qq 2>&1 | tee -a "$LOG_FILE"
            ;;
        arch)
            pacman -Sy 2>&1 | tee -a "$LOG_FILE"
            ;;
        *)
            warn "Unknown package manager. Install dependencies manually."
            return 1
            ;;
    esac
}

pkg_install() {
    local pkg="$1"
    case "$DISTRO_FAMILY" in
        debian)
            apt install -y "$pkg" 2>&1 | tee -a "$LOG_FILE"
            ;;
        arch)
            pacman -S --noconfirm --needed "$pkg" 2>&1 | tee -a "$LOG_FILE"
            ;;
        *)
            warn "Cannot install ${pkg} — unknown package manager."
            return 1
            ;;
    esac
}

check_dependencies() {
    local base_deps=(nginx certbot curl wget unzip openssl)
    local need_php=false
    local need_db=false

    case "$SITE_TYPE" in
        wordpress)  need_php=true; need_db=true ;;
        php)        need_php=true ;;
        static|proxy) ;;
    esac

    header "Checking Dependencies"
    local missing=()

    for cmd in "${base_deps[@]}"; do
        if command -v "$cmd" &>/dev/null; then
            log "${cmd} ${DIM}$(command -v "$cmd")${NC}"
        else
            missing+=("$cmd")
            warn "${cmd} — ${RED}not found${NC}"
        fi
    done

    # Check certbot nginx plugin
    if ! certbot plugins 2>/dev/null | grep -q "nginx"; then
        local certbot_nginx_pkg="python3-certbot-nginx"
        [[ "$DISTRO_FAMILY" == "arch" ]] && certbot_nginx_pkg="certbot-nginx"
        missing+=("$certbot_nginx_pkg")
        warn "certbot nginx plugin — ${RED}not found${NC}"
    else
        log "certbot nginx plugin"
    fi

    if $need_php; then
        if command -v php &>/dev/null; then
            log "php ${DIM}$(php -r 'echo PHP_VERSION;')${NC}"
        else
            missing+=("php")
            warn "php — ${RED}not found${NC}"
        fi
    else
        info "PHP not needed for ${SITE_TYPE} — skipping"
    fi

    if $need_db; then
        if command -v mysql &>/dev/null; then
            log "mysql/mariadb"
        else
            missing+=("mysql")
            warn "mysql — ${RED}not found${NC}"
        fi
    else
        info "Database not needed for ${SITE_TYPE} — skipping"
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo
        separator
        warn "Missing ${#missing[@]} package(s): ${BOLD}${missing[*]}${NC}"
        separator
        echo

        if confirm "Install missing dependencies now?"; then
            info "Updating package lists..."
            pkg_update &
            spinner $! "Updating package lists..."
            log "Package lists updated"

            local php_installed=false
            for pkg in "${missing[@]}"; do
                case "$pkg" in
                    php)
                        if ! $php_installed; then
                            if [[ "$DISTRO_FAMILY" == "arch" ]]; then
                                pkg_install php &
                                spinner $! "Installing PHP..."
                                pkg_install php-fpm &
                                spinner $! "Installing PHP-FPM..."
                                for ext in php-gd php-intl php-sodium php-imagick imagemagick; do
                                    pkg_install "$ext" &>/dev/null || true
                                done
                                # Arch PHP extensions are mostly compiled-in; enable in php.ini
                                local php_ini="/etc/php/php.ini"
                                if [[ -f "$php_ini" ]]; then
                                    for ext in mysqli curl gd mbstring xml zip intl bcmath sodium imagick; do
                                        sed -i "s/^;extension=${ext}/extension=${ext}/" "$php_ini" 2>/dev/null || true
                                    done
                                    log "PHP extensions enabled in php.ini"
                                fi
                                PHP_VERSION=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || echo "")
                                PHP_FPM_SERVICE="php-fpm"
                                PHP_POOL_DIR="/etc/php/php-fpm.d"
                            else
                                if ! find /etc/php -maxdepth 1 -mindepth 1 -type d &>/dev/null 2>&1; then
                                    PHP_VERSION=$(apt-cache search "^php[0-9]" 2>/dev/null \
                                        | grep -oP 'php\K\d+\.\d+' | sort -V | tail -1)
                                    PHP_VERSION="${PHP_VERSION:-8.2}"
                                    log "Latest available PHP: ${PHP_VERSION}"
                                fi
                                apt install -y "php${PHP_VERSION}" "php${PHP_VERSION}-fpm" 2>&1 | tee -a "$LOG_FILE" &
                                spinner $! "Installing PHP ${PHP_VERSION}..."
                                apt install -y "php${PHP_VERSION}-"{mysql,curl,gd,mbstring,xml,zip,intl,bcmath,imagick} imagemagick &>/dev/null &
                                spinner $! "Installing PHP extensions..."
                                PHP_FPM_SERVICE="php${PHP_VERSION}-fpm"
                                PHP_POOL_DIR="/etc/php/${PHP_VERSION}/fpm/pool.d"
                            fi
                            log "PHP ${PHP_VERSION} + extensions installed"
                            php_installed=true
                        fi
                        ;;
                    mysql)
                        if [[ "$DISTRO_FAMILY" == "arch" ]]; then
                            pkg_install mariadb &
                            spinner $! "Installing MariaDB..."
                            # Arch needs manual database initialization
                            if [[ ! -d /var/lib/mysql/mysql ]]; then
                                info "Initializing MariaDB data directory..."
                                mariadb-install-db --user=mysql --basedir=/usr --datadir=/var/lib/mysql 2>&1 | tee -a "$LOG_FILE"
                                log "MariaDB data directory initialized"
                            fi
                        else
                            apt install -y mariadb-server 2>&1 | tee -a "$LOG_FILE" &
                            spinner $! "Installing MariaDB..."
                        fi
                        systemctl enable --now mariadb 2>/dev/null || true
                        log "MariaDB installed and started"
                        ;;
                    *)
                        pkg_install "$pkg" &
                        spinner $! "Installing ${pkg}..."
                        log "Installed ${pkg}"
                        ;;
                esac
            done
        else
            error "Cannot continue without required dependencies."
        fi
    else
        echo
        log "${GREEN}All dependencies satisfied${NC}"
    fi
}

# ── Banner ───────────────────────────────────────────────────
show_banner() {
    echo
    echo -e "  ${BOLD}${BLUE}=================================================${NC}"
    echo -e "  ${BOLD}${WHITE}  WEB SETUP SCRIPT${NC}  ${DIM}v${VERSION}${NC}"
    echo -e "  ${DIM}  Nginx ${BULLET} WordPress ${BULLET} PHP ${BULLET} Reverse Proxy${NC}"
    echo -e "  ${BOLD}${BLUE}=================================================${NC}"
    echo -e "  ${DIM}User: ${REAL_USER} | OS: ${DISTRO_FAMILY} | PHP: ${PHP_VERSION} | Sites: ${SITES_ROOT}${NC}"
    echo
}

# ── Main Menu ────────────────────────────────────────────────
main_menu() {
    show_banner
    separator

    echo -e "  ${BOLD}${WHITE}ACTIONS${NC}"
    echo
    echo -e "    ${BOLD}${GREEN}1${NC} | Create a new site"
    echo -e "    ${BOLD}${CYAN}2${NC} | Edit a site"
    echo -e "    ${BOLD}${BLUE}3${NC} | List all sites"
    echo -e "    ${BOLD}${YELLOW}4${NC} | Renew SSL certificates"
    echo -e "    ${BOLD}${MAGENTA}5${NC} | Setup SSL auto-renewal"
    echo -e "    ${BOLD}${WHITE}6${NC} | Backup Manager"
    echo -e "    ${BOLD}${RED}7${NC} | Delete a site"
    echo -e "    ${DIM}8${NC} | Exit"
    echo
    separator
    echo -ne "  ${CYAN}${ARROW}${NC} Choose an option ${DIM}[1-8]${NC}: "
    read -r choice

    case "$choice" in
        1) create_site ;;
        2) edit_site ;;
        3) list_sites; echo; main_menu ;;
        4) renew_ssl; echo; main_menu ;;
        5) setup_ssl_auto_renewal; echo; main_menu ;;
        6) manage_backups; echo; main_menu ;;
        7) delete_site; echo; main_menu ;;
        8) echo -e "\n  ${DIM}Goodbye.${NC}\n"; exit 0 ;;
        *) warn "Invalid option."; main_menu ;;
    esac
}

# ── Site Type Menu ───────────────────────────────────────────
site_type_menu() {
    header "Select Site Type"

    echo -e "    ${BOLD}${GREEN}1${NC} | ${BOLD}Static${NC}        ${DIM}— HTML / CSS / JS${NC}"
    echo -e "    ${BOLD}${BLUE}2${NC} | ${BOLD}WordPress${NC}     ${DIM}— Full WP install with DB${NC}"
    echo -e "    ${BOLD}${MAGENTA}3${NC} | ${BOLD}PHP${NC}           ${DIM}— Custom PHP application${NC}"
    echo -e "    ${BOLD}${YELLOW}4${NC} | ${BOLD}Reverse Proxy${NC} ${DIM}— Node.js, Python, Go, etc.${NC}"
    echo
    echo -ne "  ${CYAN}${ARROW}${NC} Choose a type ${DIM}[1-4]${NC}: "
    read -r type_choice

    case "$type_choice" in
        1) SITE_TYPE="static" ;;
        2) SITE_TYPE="wordpress" ;;
        3) SITE_TYPE="php" ;;
        4) SITE_TYPE="proxy" ;;
        *) warn "Invalid option."; site_type_menu ;;
    esac

    log "Site type: ${BOLD}${SITE_TYPE}${NC}"
}

# ── Gather Site Info ─────────────────────────────────────────
gather_info() {
    header "Site Configuration"

    # Local or public?
    IS_LOCAL=false
    echo -e "    ${BOLD}${GREEN}1${NC} | ${BOLD}Public${NC}  ${DIM}-- real domain with DNS (e.g. example.com)${NC}"
    echo -e "    ${BOLD}${CYAN}2${NC} | ${BOLD}Local${NC}   ${DIM}-- local dev domain via /etc/hosts (e.g. myapp.local)${NC}"
    echo
    echo -ne "  ${CYAN}${ARROW}${NC} Public or local? ${DIM}[1-2]${NC}: "
    read -r scope_choice
    case "$scope_choice" in
        2) IS_LOCAL=true ;;
        1) IS_LOCAL=false ;;
        *) warn "Defaulting to public." ;;
    esac

    # Domain
    if $IS_LOCAL; then
        echo -ne "  ${CYAN}${ARROW}${NC} Local domain ${DIM}(e.g. myapp.local, mysite.test)${NC}: "
    else
        echo -ne "  ${CYAN}${ARROW}${NC} Domain name ${DIM}(e.g. example.com)${NC}: "
    fi
    read -r DOMAIN
    DOMAIN="${DOMAIN,,}"  # lowercase

    # Auto-append .local if user typed a bare name for local sites
    if $IS_LOCAL && [[ ! "$DOMAIN" == *.* ]]; then
        DOMAIN="${DOMAIN}.local"
        info "Auto-appended .local -> ${BOLD}${DOMAIN}${NC}"
    fi

    validate_domain "$DOMAIN"

    # Warn if mismatch between choice and TLD
    if $IS_LOCAL && ! is_local_domain "$DOMAIN"; then
        warn "${DOMAIN} doesn't look like a local domain (.local, .test, .localhost)."
        confirm "Continue anyway?" || { warn "Aborted."; main_menu; }
    fi
    if ! $IS_LOCAL && is_local_domain "$DOMAIN"; then
        warn "${DOMAIN} looks like a local domain but you chose public."
        if confirm "Switch to local mode?"; then
            IS_LOCAL=true
        fi
    fi

    SITE_DIR="${SITES_ROOT}/${DOMAIN}"
    if [[ -d "$SITE_DIR" ]]; then
        error "Site ${BOLD}${DOMAIN}${NC} already exists at ${SITE_DIR}"
    fi

    # www redirect (skip for local -- not useful)
    HANDLE_WWW=false
    if ! $IS_LOCAL; then
        if confirm "Also handle www.${DOMAIN}?"; then
            HANDLE_WWW=true
        fi
    fi

    # Proxy port
    if [[ "$SITE_TYPE" == "proxy" ]]; then
        echo -ne "  ${CYAN}${ARROW}${NC} Backend port ${DIM}(e.g. 3000)${NC}: "
        read -r PROXY_PORT
        validate_port "$PROXY_PORT"
    fi

    # SSL (skip for local sites)
    SETUP_SSL=false
    if $IS_LOCAL; then
        info "SSL skipped for local domain (use http://${DOMAIN})"
    else
        if confirm "Set up SSL with Let's Encrypt?"; then
            SETUP_SSL=true
            echo -ne "  ${CYAN}${ARROW}${NC} Email for SSL certificate: "
            read -r SSL_EMAIL
            validate_email "$SSL_EMAIL"
        fi
    fi

    # Summary before proceeding
    echo
    separator
    echo -e "  ${BOLD}${WHITE}Configuration Summary${NC}"
    echo -e "    Domain:   ${BOLD}${DOMAIN}${NC}"
    echo -e "    Type:     ${BOLD}${SITE_TYPE}${NC}"
    echo -e "    Mode:     ${BOLD}$( $IS_LOCAL && echo "LOCAL (127.0.0.1)" || echo "PUBLIC" )${NC}"
    echo -e "    WWW:      ${HANDLE_WWW}"
    echo -e "    SSL:      ${SETUP_SSL}"
    echo -e "    Path:     ${SITE_DIR}"
    [[ "$SITE_TYPE" == "proxy" ]] && echo -e "    Backend:  127.0.0.1:${PROXY_PORT}"
    separator
    echo

    confirm "Proceed with this configuration?" || { warn "Aborted."; main_menu; }
}

# ── Create Directories ───────────────────────────────────────
create_directories() {
    info "Creating site directories..."
    mkdir -p "${SITE_DIR}"/{public,logs,backups}

    # nginx (${WEB_USER}) needs to traverse the home directory
    chmod o+x "/home/${REAL_USER}"

    chown -R "${WEB_USER}:${WEB_USER}" "${SITE_DIR}/public"
    chown -R "${REAL_USER}:${WEB_USER}" "${SITE_DIR}/logs"
    chown -R "${REAL_USER}:${WEB_USER}" "${SITE_DIR}/backups"
    chmod -R 755 "$SITE_DIR"
    log "Directories created at ${DIM}${SITE_DIR}${NC}"
}

# ── Database Setup ───────────────────────────────────────────
setup_database() {
    header "Database Setup"
    DB_NAME="${DOMAIN//[.-]/_}"
    DB_USER="${DB_NAME:0:16}_usr"
    DB_PASS=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24)

    # Check MariaDB/MySQL is running
    if ! systemctl is-active --quiet mariadb 2>/dev/null && ! systemctl is-active --quiet mysql 2>/dev/null; then
        warn "MariaDB/MySQL is not running. Attempting to start..."
        systemctl start mariadb 2>/dev/null || systemctl start mysql 2>/dev/null || \
            error "Could not start database server. Start it manually and re-run."
    fi

    info "Creating database: ${BOLD}${DB_NAME}${NC}"
    mysql -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" || \
        error "Failed to create database. Check MySQL/MariaDB."
    mysql -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';"
    mysql -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';"
    mysql -e "FLUSH PRIVILEGES;"

    # Save credentials (restricted permissions)
    cat > "${SITE_DIR}/db-credentials.txt" <<EOF
======================================
       DATABASE CREDENTIALS
======================================

DB Name:     ${DB_NAME}
DB User:     ${DB_USER}
DB Password: ${DB_PASS}
DB Host:     localhost

Generated:   $(date)
WARNING:     Keep this file secure!
EOF
    chmod 600 "${SITE_DIR}/db-credentials.txt"
    chown "${REAL_USER}:${REAL_USER}" "${SITE_DIR}/db-credentials.txt"
    log "Database ${BOLD}${DB_NAME}${NC} created"
    log "Credentials saved to ${DIM}db-credentials.txt${NC}"
}

# ── Install WordPress ────────────────────────────────────────
install_wordpress() {
    header "Installing WordPress"
    local tmp_dir
    tmp_dir=$(mktemp -d)

    info "Downloading WordPress..."
    wget -q https://wordpress.org/latest.tar.gz -O "${tmp_dir}/wordpress.tar.gz" &
    spinner $! "Downloading WordPress..."

    if [[ ! -f "${tmp_dir}/wordpress.tar.gz" ]]; then
        rm -rf "$tmp_dir"
        error "Failed to download WordPress. Check your internet connection."
    fi

    tar -xzf "${tmp_dir}/wordpress.tar.gz" -C "$tmp_dir"
    cp -r "${tmp_dir}/wordpress/." "${SITE_DIR}/public/"
    rm -rf "$tmp_dir"

    # Configure wp-config.php
    cp "${SITE_DIR}/public/wp-config-sample.php" "${SITE_DIR}/public/wp-config.php"
    sed -i "s/database_name_here/${DB_NAME}/" "${SITE_DIR}/public/wp-config.php"
    sed -i "s/username_here/${DB_USER}/"       "${SITE_DIR}/public/wp-config.php"
    sed -i "s/password_here/${DB_PASS}/"       "${SITE_DIR}/public/wp-config.php"

    # Allow WordPress to write directly without FTP prompt
    # This is needed because SFTP jailing changes ownership away from ${WEB_USER}
    if ! grep -q "FS_METHOD" "${SITE_DIR}/public/wp-config.php"; then
        sed -i "/table_prefix/a\\
\\
/** Force direct filesystem writes (no FTP prompt) */\\
define('FS_METHOD', 'direct');" "${SITE_DIR}/public/wp-config.php"
        log "FS_METHOD set to 'direct' (no FTP prompt)"
    fi

    # Generate security keys
    info "Fetching WordPress security salts..."
    local SALT
    SALT=$(curl -sS --max-time 10 https://api.wordpress.org/secret-key/1.1/salt/ 2>/dev/null) || true

    if [[ -n "$SALT" ]] && [[ "$SALT" == *"define"* ]]; then
        # Remove all placeholder key lines
        sed -i "/define( 'AUTH_KEY'/d"         "${SITE_DIR}/public/wp-config.php"
        sed -i "/define( 'SECURE_AUTH_KEY'/d"  "${SITE_DIR}/public/wp-config.php"
        sed -i "/define( 'LOGGED_IN_KEY'/d"    "${SITE_DIR}/public/wp-config.php"
        sed -i "/define( 'NONCE_KEY'/d"        "${SITE_DIR}/public/wp-config.php"
        sed -i "/define( 'AUTH_SALT'/d"        "${SITE_DIR}/public/wp-config.php"
        sed -i "/define( 'SECURE_AUTH_SALT'/d" "${SITE_DIR}/public/wp-config.php"
        sed -i "/define( 'LOGGED_IN_SALT'/d"   "${SITE_DIR}/public/wp-config.php"
        sed -i "/define( 'NONCE_SALT'/d"       "${SITE_DIR}/public/wp-config.php"

        # Insert real salts after the "put your unique phrase" comment
        local tmp_conf
        tmp_conf=$(mktemp)
        awk -v salts="$SALT" '
            /put your unique phrase/ { print; print salts; next }
            { print }
        ' "${SITE_DIR}/public/wp-config.php" > "$tmp_conf"
        mv "$tmp_conf" "${SITE_DIR}/public/wp-config.php"
        log "WordPress security salts injected"
    else
        warn "Could not fetch security salts. Update them manually in wp-config.php"
    fi

    # Set correct permissions
    find "${SITE_DIR}/public" -type d -exec chmod 755 {} \;
    find "${SITE_DIR}/public" -type f -exec chmod 644 {} \;
    chown -R ${WEB_USER}:${WEB_USER} "${SITE_DIR}/public"
    log "WordPress installed successfully"
}

# ── Static Placeholder ───────────────────────────────────────
create_static_placeholder() {
    cat > "${SITE_DIR}/public/index.html" <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>${DOMAIN}</title>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
      display: flex; justify-content: center; align-items: center;
      min-height: 100vh; background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
    }
    .card {
      text-align: center; padding: 3rem; background: white;
      border-radius: 16px; box-shadow: 0 20px 60px rgba(0,0,0,.2);
      max-width: 500px; margin: 1rem;
    }
    h1 { color: #333; margin-bottom: 0.5rem; font-size: 2rem; }
    p { color: #666; line-height: 1.6; }
    code { background: #f4f4f5; padding: 2px 8px; border-radius: 4px; font-size: 0.9rem; }
  </style>
</head>
<body>
  <div class="card">
    <h1>${DOMAIN}</h1>
    <p>Your site is live! Upload your files to:<br><code>${SITE_DIR}/public/</code></p>
  </div>
</body>
</html>
EOF
    chown ${WEB_USER}:${WEB_USER} "${SITE_DIR}/public/index.html"
    log "Static placeholder created"
}

# ── PHP-FPM Pool ─────────────────────────────────────────────
setup_php_pool() {
    info "Creating PHP-FPM pool for ${BOLD}${DOMAIN}${NC}..."
    POOL_NAME="${DOMAIN//[.-]/_}"
    POOL_FILE="${PHP_POOL_DIR}/${POOL_NAME}.conf"
    if [[ "$DISTRO_FAMILY" == "arch" ]]; then
        SOCK="/run/php-fpm/${POOL_NAME}.sock"
        mkdir -p /run/php-fpm
    else
        SOCK="/run/php/${POOL_NAME}.sock"
    fi

    cat > "$POOL_FILE" <<EOF
[${POOL_NAME}]
user = ${WEB_USER}
group = ${WEB_USER}
listen = ${SOCK}
listen.owner = ${WEB_USER}
listen.group = ${WEB_USER}
listen.mode = 0660

pm = dynamic
pm.max_children = 10
pm.start_servers = 2
pm.min_spare_servers = 1
pm.max_spare_servers = 3
pm.max_requests = 500

; Logging
php_admin_value[error_log] = ${SITE_DIR}/logs/php_error.log
php_admin_flag[log_errors] = on

; Limits
php_value[upload_max_filesize] = 64M
php_value[post_max_size] = 64M
php_value[max_execution_time] = 300
php_value[memory_limit] = 256M

; Security
php_admin_value[open_basedir] = ${SITE_DIR}/public:/tmp
php_admin_value[disable_functions] = exec,passthru,shell_exec,system,proc_open,popen
EOF

    systemctl restart "${PHP_FPM_SERVICE}" || error "Failed to restart PHP-FPM. Check the pool config."
    PHP_SOCK="$SOCK"
    log "PHP-FPM pool created: ${DIM}${POOL_FILE}${NC}"
}

# ── Nginx Config ─────────────────────────────────────────────
create_nginx_config() {
    header "Nginx Configuration"
    NGINX_CONF="${NGINX_SITES}/${DOMAIN}"

    # Build server_name
    SERVER_NAME_LINE="${DOMAIN}"
    $HANDLE_WWW && SERVER_NAME_LINE+=" www.${DOMAIN}"

    case "$SITE_TYPE" in

      static)
        cat > "$NGINX_CONF" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${SERVER_NAME_LINE};

    root ${SITE_DIR}/public;
    index index.html index.htm;

    access_log ${SITE_DIR}/logs/access.log;
    error_log  ${SITE_DIR}/logs/error.log;

    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "no-referrer-when-downgrade" always;
    add_header Content-Security-Policy "default-src 'self'" always;

    location / {
        try_files \$uri \$uri/ =404;
    }

    # Cache static assets
    location ~* \.(css|js|jpg|jpeg|png|gif|ico|svg|woff2?|ttf|eot)$ {
        expires 30d;
        add_header Cache-Control "public, immutable";
        access_log off;
    }

    # Deny hidden files
    location ~ /\. {
        deny all;
        access_log off;
        log_not_found off;
    }
}
EOF
        ;;

      wordpress)
        cat > "$NGINX_CONF" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${SERVER_NAME_LINE};

    root ${SITE_DIR}/public;
    index index.php index.html;

    access_log ${SITE_DIR}/logs/access.log;
    error_log  ${SITE_DIR}/logs/error.log;

    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "no-referrer-when-downgrade" always;

    # WordPress permalinks
    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    # PHP-FPM
    location ~ \.php$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        try_files \$fastcgi_script_name =404;
        fastcgi_pass unix:${PHP_SOCK};
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_read_timeout 300;
        fastcgi_buffers 16 16k;
        fastcgi_buffer_size 32k;
    }

    # Block xmlrpc (brute force vector)
    location = /xmlrpc.php { deny all; access_log off; log_not_found off; }

    # Protect wp-config
    location = /wp-config.php { deny all; access_log off; log_not_found off; }

    # Protect wp-includes
    location ~* wp-admin/includes { deny all; }
    location ~* wp-includes/theme-compat/ { deny all; }
    location ~* wp-includes/js/tinymce/langs/.+\.php { deny all; }

    # Cache static assets
    location ~* \.(css|js|jpg|jpeg|png|gif|ico|svg|woff2?|ttf|eot|webp)$ {
        expires 30d;
        add_header Cache-Control "public, immutable";
        access_log off;
        log_not_found off;
    }

    # Deny hidden files
    location ~ /\. { deny all; access_log off; log_not_found off; }

    # Deny PHP in uploads
    location ~* /(?:uploads|files)/.*\.php$ { deny all; }

    client_max_body_size 64M;
}
EOF
        ;;

      php)
        cat > "$NGINX_CONF" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${SERVER_NAME_LINE};

    root ${SITE_DIR}/public;
    index index.php index.html;

    access_log ${SITE_DIR}/logs/access.log;
    error_log  ${SITE_DIR}/logs/error.log;

    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        try_files \$fastcgi_script_name =404;
        fastcgi_pass unix:${PHP_SOCK};
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_read_timeout 300;
    }

    location ~ /\. { deny all; access_log off; log_not_found off; }

    client_max_body_size 64M;
}
EOF
        ;;

      proxy)
        cat > "$NGINX_CONF" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${SERVER_NAME_LINE};

    access_log ${SITE_DIR}/logs/access.log;
    error_log  ${SITE_DIR}/logs/error.log;

    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;

    location / {
        proxy_pass         http://127.0.0.1:${PROXY_PORT};
        proxy_http_version 1.1;
        proxy_set_header   Upgrade \$http_upgrade;
        proxy_set_header   Connection 'upgrade';
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
        proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
        proxy_read_timeout 300;
        proxy_connect_timeout 60;
        proxy_send_timeout 300;
    }

    # Health check endpoint (optional)
    location /health {
        access_log off;
        proxy_pass http://127.0.0.1:${PROXY_PORT}/health;
    }
}
EOF
        ;;
    esac

    # Validate and enable nginx
    ln -sf "$NGINX_CONF" "${NGINX_ENABLED}/${DOMAIN}"
    info "Testing nginx configuration..."
    if nginx -t 2>&1; then
        if systemctl is-active --quiet nginx 2>/dev/null; then
            systemctl reload nginx
            log "Nginx configured and reloaded"
        else
            systemctl enable --now nginx
            log "Nginx enabled and started"
        fi
    else
        rm -f "${NGINX_ENABLED}/${DOMAIN}"
        error "Nginx config test failed. Check: ${NGINX_CONF}"
    fi
}

# ── SSL Setup ────────────────────────────────────────────────
setup_ssl() {
    header "SSL Certificate (Let's Encrypt)"

    # Pre-check: ensure domain resolves (basic check)
    info "Verifying domain DNS..."
    if ! host "$DOMAIN" &>/dev/null && ! dig +short "$DOMAIN" 2>/dev/null | grep -q '.'; then
        warn "DNS lookup for ${DOMAIN} failed. SSL may fail if the domain doesn't point to this server."
        confirm "Try anyway?" || return
    fi

    info "Requesting certificate for ${BOLD}${DOMAIN}${NC}..."
    CERTBOT_DOMAINS="-d ${DOMAIN}"
    $HANDLE_WWW && CERTBOT_DOMAINS+=" -d www.${DOMAIN}"

    if certbot --nginx \
        --non-interactive \
        --agree-tos \
        --email "$SSL_EMAIL" \
        --redirect \
        $CERTBOT_DOMAINS 2>&1 | tee -a "$LOG_FILE"; then
        log "SSL certificate installed for ${BOLD}${DOMAIN}${NC}"
    else
        warn "SSL certificate request failed. You can retry later with:"
        echo -e "  ${DIM}sudo certbot --nginx -d ${DOMAIN}${NC}"
    fi
}

# ── SSL Auto-Renewal Setup ───────────────────────────────────
setup_ssl_auto_renewal() {
    header "SSL Auto-Renewal Setup"

    local renewal_active=false

    # Check if systemd timer exists and is active
    if systemctl list-timers --all 2>/dev/null | grep -q "certbot"; then
        log "Certbot systemd timer found"
        if systemctl is-active --quiet certbot.timer 2>/dev/null; then
            log "Timer is ${GREEN}active${NC}"
            renewal_active=true
        else
            warn "Timer exists but is ${RED}inactive${NC}"
            info "Enabling certbot timer..."
            systemctl enable --now certbot.timer
            log "Certbot timer enabled and started"
            renewal_active=true
        fi
    fi

    # Check if cron job exists
    if [[ -f /etc/cron.d/certbot ]]; then
        log "Certbot cron job found at /etc/cron.d/certbot"
        renewal_active=true
    fi

    # If nothing is set up, create a systemd timer
    if ! $renewal_active; then
        warn "No auto-renewal mechanism detected."
        info "Setting up systemd timer for certbot..."

        # Create the service unit if it doesn't exist
        if [[ ! -f /etc/systemd/system/certbot-renew.service ]]; then
            cat > /etc/systemd/system/certbot-renew.service <<'EOF'
[Unit]
Description=Certbot SSL certificate renewal
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/certbot renew --quiet --deploy-hook "systemctl reload nginx"
EOF
            log "Created certbot-renew.service"
        fi

        # Create the timer unit if it doesn't exist
        if [[ ! -f /etc/systemd/system/certbot-renew.timer ]]; then
            cat > /etc/systemd/system/certbot-renew.timer <<'EOF'
[Unit]
Description=Twice-daily certbot renewal check

[Timer]
OnCalendar=*-*-* 00,12:00:00
RandomizedDelaySec=3600
Persistent=true

[Install]
WantedBy=timers.target
EOF
            log "Created certbot-renew.timer"
        fi

        systemctl daemon-reload
        systemctl enable --now certbot-renew.timer
        log "Certbot auto-renewal timer ${GREEN}activated${NC}"
        renewal_active=true
    fi

    # Ensure deploy hook reloads nginx on any renewal
    local renew_hook_dir="/etc/letsencrypt/renewal-hooks/deploy"
    if [[ -d "/etc/letsencrypt" ]]; then
        mkdir -p "$renew_hook_dir"
        if [[ ! -f "${renew_hook_dir}/reload-nginx.sh" ]]; then
            cat > "${renew_hook_dir}/reload-nginx.sh" <<'EOF'
#!/bin/bash
# Reload nginx after certificate renewal so it picks up new certs
systemctl reload nginx
EOF
            chmod +x "${renew_hook_dir}/reload-nginx.sh"
            log "Deploy hook created: nginx will reload after each renewal"
        else
            log "Deploy hook already exists"
        fi
    fi

    # Test renewal (dry run)
    echo
    if confirm "Run a dry-run renewal test?"; then
        info "Testing renewal..."
        if certbot renew --dry-run 2>&1 | tee -a "$LOG_FILE"; then
            log "${GREEN}Dry run successful${NC} — auto-renewal is working"
        else
            warn "Dry run had issues. Check the output above."
        fi
    fi

    # Show status summary
    echo
    separator
    echo -e "  ${BOLD}${WHITE}Auto-Renewal Status${NC}"
    echo

    if systemctl is-active --quiet certbot.timer 2>/dev/null; then
        echo -e "    ${GREEN}${CHECK}${NC} certbot.timer is active"
        local next_run
        next_run=$(systemctl list-timers certbot.timer 2>/dev/null | grep certbot | awk '{print $1, $2, $3}')
        [[ -n "$next_run" ]] && echo -e "    ${DIM}Next run: ${next_run}${NC}"
    elif systemctl is-active --quiet certbot-renew.timer 2>/dev/null; then
        echo -e "    ${GREEN}${CHECK}${NC} certbot-renew.timer is active"
        local next_run
        next_run=$(systemctl list-timers certbot-renew.timer 2>/dev/null | grep certbot | awk '{print $1, $2, $3}')
        [[ -n "$next_run" ]] && echo -e "    ${DIM}Next run: ${next_run}${NC}"
    fi

    if [[ -f /etc/cron.d/certbot ]]; then
        echo -e "    ${GREEN}${CHECK}${NC} Cron job active at /etc/cron.d/certbot"
    fi

    if [[ -f "${renew_hook_dir}/reload-nginx.sh" ]]; then
        echo -e "    ${GREEN}${CHECK}${NC} Nginx reload hook installed"
    fi

    echo
    separator
    log "SSL auto-renewal setup complete"
}

# ── Summary ──────────────────────────────────────────────────
print_summary() {
    echo
    echo -e "  ${BOLD}${GREEN}=================================================${NC}"
    echo -e "  ${BOLD}${WHITE}  SITE SETUP COMPLETE${NC}"
    echo -e "  ${BOLD}${GREEN}=================================================${NC}"
    echo
    local proto="http"
    $SETUP_SSL && proto="https"

    echo -e "    ${BOLD}Domain${NC}      | ${DOMAIN}"
    echo -e "    ${BOLD}Type${NC}        | ${SITE_TYPE}"
    $IS_LOCAL && echo -e "    ${BOLD}Mode${NC}        | ${CYAN}LOCAL${NC} (127.0.0.1 via /etc/hosts)" \
              || echo -e "    ${BOLD}Mode${NC}        | PUBLIC"
    echo -e "    ${BOLD}URL${NC}         | ${BOLD}${UNDERLINE}${proto}://${DOMAIN}${NC}"
    echo -e "    ${BOLD}Root${NC}        | ${SITE_DIR}/public"
    echo -e "    ${BOLD}Logs${NC}        | ${SITE_DIR}/logs"

    if [[ "$SITE_TYPE" == "wordpress" || "$SITE_TYPE" == "php" ]]; then
        echo -e "    ${BOLD}Database${NC}    | ${DB_NAME:-n/a}"
    fi

    echo -e "    ${BOLD}SSL${NC}         | ${SETUP_SSL}"
    echo -e "    ${BOLD}Nginx conf${NC}  | ${NGINX_SITES}/${DOMAIN}"

    if [[ "$SITE_TYPE" == "proxy" ]]; then
        echo -e "    ${BOLD}Backend${NC}     | 127.0.0.1:${PROXY_PORT}"
    fi

    local UDIR="${SITE_DIR}/users"
    if [[ -d "$UDIR" ]] && [[ -n "$(ls -A "$UDIR" 2>/dev/null)" ]]; then
        local users_list=""
        for f in "$UDIR"/*.txt; do
            local u
            u=$(grep "Username:" "$f" | awk '{print $2}')
            users_list="${users_list} ${u}"
        done
        echo -e "    ${BOLD}SFTP users${NC}  | ${users_list}"
    fi

    echo
    separator

    if [[ "$SITE_TYPE" == "wordpress" ]]; then
        echo
        echo -e "  ${YELLOW}${ARROW} Complete WordPress setup at:${NC}"
        echo -e "    ${BOLD}${UNDERLINE}${proto}://${DOMAIN}/wp-admin/install.php${NC}"
        echo
    fi

    echo -e "  ${DIM}Full log: ${LOG_FILE}${NC}"
    echo
}

# ── SFTP Access User ─────────────────────────────────────────
setup_access_user() {
    header "Site Access User (Optional)"
    info "Create a restricted SFTP user jailed to: ${SITE_DIR}/public"

    confirm "Create a restricted SFTP user for ${DOMAIN}?" || return 0

    echo -ne "  ${CYAN}${ARROW}${NC} Username: "
    read -r ACCESS_USER
    [[ -z "$ACCESS_USER" ]] && warn "No username entered, skipping." && return 0
    validate_username "$ACCESS_USER"

    # Ensure internal-sftp subsystem (handle tabs/spaces in existing config)
    if ! grep -qP '^Subsystem\s+sftp\s+internal-sftp' /etc/ssh/sshd_config; then
        if grep -qP '^Subsystem\s+sftp' /etc/ssh/sshd_config; then
            sed -i -E 's|^Subsystem[[:space:]]+sftp[[:space:]]+.*|Subsystem sftp internal-sftp|' /etc/ssh/sshd_config
        else
            echo "Subsystem sftp internal-sftp" >> /etc/ssh/sshd_config
        fi
        log "sshd: Subsystem sftp set to internal-sftp"
    fi

    # Create system user
    if id "$ACCESS_USER" &>/dev/null; then
        warn "User ${ACCESS_USER} already exists — updating configuration."
    else
        useradd -M -s ${NOLOGIN_SHELL} "$ACCESS_USER"
        log "System user ${ACCESS_USER} created (no shell, no home)"
    fi

    passwd "$ACCESS_USER"
    usermod -aG ${WEB_USER} "$ACCESS_USER"

    # Chroot jail directory setup
    local JAIL_DIR="${SITE_DIR}"
    local UPLOAD_DIR="${SITE_DIR}/public"

    chown root:root "$JAIL_DIR"
    chmod 755 "$JAIL_DIR"
    chown -R "${ACCESS_USER}:${WEB_USER}" "$UPLOAD_DIR"
    chmod -R 775 "$UPLOAD_DIR"
    find "$UPLOAD_DIR" -type d -exec chmod g+s {} \;

    # WordPress fix: ensure ${WEB_USER} can still write to wp-content
    # (plugins, themes, uploads) after SFTP user takes ownership
    if [[ -d "${UPLOAD_DIR}/wp-content" ]]; then
        chown -R ${WEB_USER}:${WEB_USER} "${UPLOAD_DIR}/wp-content"
        chmod -R 775 "${UPLOAD_DIR}/wp-content"
        find "${UPLOAD_DIR}/wp-content" -type d -exec chmod g+s {} \;
        # Ensure FS_METHOD is set in wp-config
        if [[ -f "${UPLOAD_DIR}/wp-config.php" ]] && ! grep -q "FS_METHOD" "${UPLOAD_DIR}/wp-config.php"; then
            sed -i "/table_prefix/a\\
\\
/** Force direct filesystem writes (no FTP prompt) */\\
define('FS_METHOD', 'direct');" "${UPLOAD_DIR}/wp-config.php"
        fi
        log "WordPress wp-content ownership preserved for ${WEB_USER}"
    fi

    # sshd_config Match User block
    if grep -q "Match User ${ACCESS_USER}" /etc/ssh/sshd_config; then
        warn "Removing old sshd entry for ${ACCESS_USER}."
        sed -i "/# SFTP jail.*${ACCESS_USER}/,+5d" /etc/ssh/sshd_config
        sed -i "/Match User ${ACCESS_USER}/,+4d" /etc/ssh/sshd_config
    fi

    cat >> /etc/ssh/sshd_config <<EOF

# SFTP jail for ${DOMAIN} — managed by setup-site.sh
Match User ${ACCESS_USER}
    ChrootDirectory ${JAIL_DIR}
    ForceCommand internal-sftp -d /public
    AllowTcpForwarding no
    X11Forwarding no
    PasswordAuthentication yes
EOF

    if sshd -t 2>/dev/null; then
        systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null
        log "sshd restarted with chroot jail for ${ACCESS_USER}"
    else
        error "sshd config test failed. Check /etc/ssh/sshd_config"
    fi

    # Parent dirs must be root-owned and 755 for chroot to work
    # Every directory in the chroot path must be owned by root and not writable by others
    chown root:root "/home/${REAL_USER}" 2>/dev/null || true
    chmod 755 "/home/${REAL_USER}" 2>/dev/null || true
    chown root:root "${SITES_ROOT}" 2>/dev/null || true
    chmod 755 "${SITES_ROOT}" 2>/dev/null || true
    chown root:root "${SITE_DIR}" 2>/dev/null || true
    chmod 755 "${SITE_DIR}" 2>/dev/null || true

    save_user_record "$DOMAIN" "$ACCESS_USER" "$SITE_DIR"

    echo
    echo -e "  ${GREEN}${BOLD}SFTP User Ready${NC}"
    separator
    echo -e "    ${BOLD}Username${NC}    | ${ACCESS_USER}"
    echo -e "    ${BOLD}Protocol${NC}    | SFTP (port 22)"
    echo -e "    ${BOLD}Jailed to${NC}   | /public"
    echo -e "    ${BOLD}FileZilla${NC}   | SFTP / your-server-ip / 22 / ${ACCESS_USER}"
    separator
    echo
}

# ── Create Site Orchestrator ─────────────────────────────────
create_site() {
    site_type_menu
    check_dependencies
    gather_info
    create_directories

    case "$SITE_TYPE" in
        wordpress)
            setup_database
            install_wordpress
            setup_php_pool
            ;;
        php)
            if confirm "Does this PHP app need a database?"; then
                setup_database
            fi
            setup_php_pool
            ;;
        static)
            create_static_placeholder
            ;;
        proxy) ;;
    esac

    create_nginx_config

    # Add to /etc/hosts for local domains
    if $IS_LOCAL; then
        add_to_hosts "$DOMAIN"
        $HANDLE_WWW && add_to_hosts "www.${DOMAIN}"
    fi

    $SETUP_SSL && setup_ssl
    setup_access_user
    print_summary

    # Offer auto-renewal setup if SSL was configured
    if $SETUP_SSL; then
        if confirm "Set up automatic SSL renewal?"; then
            setup_ssl_auto_renewal
        fi
    fi
}

# ── Site Type Detection ──────────────────────────────────────
detect_site_type() {
    local domain="$1"
    local site_dir="${SITES_ROOT}/${domain}"
    local nginx_conf="${NGINX_SITES}/${domain}"

    if [[ -f "${site_dir}/public/wp-config.php" ]]; then
        echo "wordpress"
    elif grep -q "proxy_pass" "$nginx_conf" 2>/dev/null; then
        echo "proxy"
    elif [[ -f "${PHP_POOL_DIR}/${domain//[.-]/_}.conf" ]]; then
        echo "php"
    else
        echo "static"
    fi
}

# ── Update WordPress ────────────────────────────────────────
update_wordpress() {
    local domain="$1"
    local site_dir="${SITES_ROOT}/${domain}/public"

    header "Update WordPress: ${domain}"

    # Check/install WP-CLI
    if ! command -v wp &>/dev/null; then
        info "WP-CLI not found. Installing..."
        if [[ "$DISTRO_FAMILY" == "arch" ]]; then
            pkg_install wp-cli &>/dev/null || {
                curl -sO https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
                chmod +x wp-cli.phar
                mv wp-cli.phar /usr/local/bin/wp
            }
        else
            curl -sO https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
            chmod +x wp-cli.phar
            mv wp-cli.phar /usr/local/bin/wp
        fi
        if command -v wp &>/dev/null; then
            log "WP-CLI installed"
        else
            error "Failed to install WP-CLI."
            return 1
        fi
    fi

    local wp_cmd="sudo -u ${WEB_USER} wp --path=${site_dir}"

    # Show current version
    local current_ver
    current_ver=$($wp_cmd core version 2>/dev/null || echo "unknown")
    info "Current WordPress version: ${BOLD}${current_ver}${NC}"

    # Core update
    if confirm "Update WordPress core?"; then
        $wp_cmd core update 2>&1 | tee -a "$LOG_FILE" &
        spinner $! "Updating WordPress core..."
        $wp_cmd core update-db 2>/dev/null || true
        log "WordPress core updated"
    fi

    # Plugin updates
    local outdated_plugins
    outdated_plugins=$($wp_cmd plugin list --update=available --format=csv 2>/dev/null | tail -n +2)
    if [[ -n "$outdated_plugins" ]]; then
        info "Plugins with updates available:"
        echo "$outdated_plugins" | while IFS=',' read -r name status update version; do
            echo -e "    ${CYAN}-${NC} ${name} (${status} ${DIM}${version}${NC})"
        done
        if confirm "Update all plugins?"; then
            $wp_cmd plugin update --all 2>&1 | tee -a "$LOG_FILE" &
            spinner $! "Updating plugins..."
            log "All plugins updated"
        fi
    else
        info "All plugins are up to date."
    fi

    # Theme updates
    local outdated_themes
    outdated_themes=$($wp_cmd theme list --update=available --format=csv 2>/dev/null | tail -n +2)
    if [[ -n "$outdated_themes" ]]; then
        info "Themes with updates available:"
        echo "$outdated_themes" | while IFS=',' read -r name status update version; do
            echo -e "    ${CYAN}-${NC} ${name} (${status} ${DIM}${version}${NC})"
        done
        if confirm "Update all themes?"; then
            $wp_cmd theme update --all 2>&1 | tee -a "$LOG_FILE" &
            spinner $! "Updating themes..."
            log "All themes updated"
        fi
    else
        info "All themes are up to date."
    fi

    log "WordPress update complete for ${domain}"
}

# ── Update PHP Extensions ───────────────────────────────────
update_php_extensions() {
    local domain="$1"

    header "Update PHP Extensions: ${domain}"

    # Show currently loaded extensions
    local loaded_exts
    loaded_exts=$(php -m 2>/dev/null | grep -v '^\[' | sort)
    info "Currently loaded PHP extensions:"
    echo "$loaded_exts" | while read -r ext; do
        [[ -n "$ext" ]] && echo -e "    ${GREEN}${CHECK}${NC} ${ext}"
    done
    echo

    # Recommended extensions for WordPress/PHP sites
    local -a recommended=("imagick" "redis" "apcu" "opcache")
    local -a missing=()

    for ext in "${recommended[@]}"; do
        if ! php -m 2>/dev/null | grep -qi "^${ext}$"; then
            missing+=("$ext")
        fi
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        info "All recommended extensions are installed."
        return
    fi

    info "Missing recommended extensions:"
    local i=1
    for ext in "${missing[@]}"; do
        local desc=""
        case "$ext" in
            imagick) desc="Image processing (AVIF, WebP, SVG support)" ;;
            redis)   desc="Object caching for better performance" ;;
            apcu)    desc="In-memory object cache" ;;
            opcache) desc="PHP bytecode caching" ;;
        esac
        echo -e "    ${YELLOW}${i}${NC} | ${BOLD}${ext}${NC} ${DIM}-- ${desc}${NC}"
        (( i++ ))
    done
    echo

    echo -ne "  ${CYAN}${ARROW}${NC} Extensions to install ${DIM}(comma-separated numbers, or 'all')${NC}: "
    read -r ext_choice

    local -a to_install=()
    if [[ "${ext_choice,,}" == "all" ]]; then
        to_install=("${missing[@]}")
    elif [[ -n "$ext_choice" ]]; then
        IFS=',' read -ra nums <<< "$ext_choice"
        for num in "${nums[@]}"; do
            num=$(echo "$num" | tr -d ' ')
            if [[ "$num" =~ ^[0-9]+$ ]] && (( num >= 1 && num <= ${#missing[@]} )); then
                to_install+=("${missing[$((num-1))]}")
            fi
        done
    fi

    if [[ ${#to_install[@]} -eq 0 ]]; then
        info "No extensions selected."
        return
    fi

    # Build a single package list for batch install
    local -a pkg_list=()
    for ext in "${to_install[@]}"; do
        if [[ "$DISTRO_FAMILY" == "arch" ]]; then
            [[ "$ext" == "opcache" ]] && continue # built-in on Arch
            pkg_list+=("php-${ext}")
            [[ "$ext" == "imagick" ]] && pkg_list+=("imagemagick")
        else
            case "$ext" in
                imagick)  pkg_list+=("php${PHP_VERSION}-imagick" "imagemagick") ;;
                opcache)  pkg_list+=("php${PHP_VERSION}-opcache") ;;
                *)        pkg_list+=("php${PHP_VERSION}-${ext}") ;;
            esac
        fi
    done

    if [[ ${#pkg_list[@]} -gt 0 ]]; then
        info "Installing: ${pkg_list[*]}"
        if [[ "$DISTRO_FAMILY" == "arch" ]]; then
            pacman -S --noconfirm --needed "${pkg_list[@]}" 2>&1 | tee -a "$LOG_FILE" &
            spinner $! "Installing extensions..."
        else
            DEBIAN_FRONTEND=noninteractive apt install -y "${pkg_list[@]}" 2>&1 | tee -a "$LOG_FILE" &
            spinner $! "Installing extensions..."
        fi
        # Enable extensions in php.ini (Arch only)
        if [[ "$DISTRO_FAMILY" == "arch" ]]; then
            local php_ini="/etc/php/php.ini"
            if [[ -f "$php_ini" ]]; then
                for ext in "${to_install[@]}"; do
                    sed -i "s/^;extension=${ext}/extension=${ext}/" "$php_ini" 2>/dev/null || true
                    sed -i "s/^;zend_extension=${ext}/zend_extension=${ext}/" "$php_ini" 2>/dev/null || true
                done
            fi
        fi
        for ext in "${to_install[@]}"; do
            log "${ext} installed"
        done
    fi

    # Restart PHP-FPM to load new extensions
    systemctl restart "${PHP_FPM_SERVICE}" 2>/dev/null || true
    log "PHP-FPM restarted to load new extensions"
}

# ── Toggle SSL ──────────────────────────────────────────────
toggle_ssl() {
    local domain="$1"
    local cert_path="/etc/letsencrypt/live/${domain}/fullchain.pem"

    header "SSL Management: ${domain}"

    # Check if this is a local domain
    if is_local_domain "$domain"; then
        warn "SSL is not available for local domains (.local, .test, .localhost)."
        info "Use ${DIM}http://${domain}${NC} instead."
        return
    fi

    if [[ -f "$cert_path" ]]; then
        # SSL exists — show status
        local expiry
        expiry=$(openssl x509 -enddate -noout -in "$cert_path" 2>/dev/null | cut -d= -f2)
        local expiry_epoch
        expiry_epoch=$(date -d "$expiry" +%s 2>/dev/null)
        local now_epoch
        now_epoch=$(date +%s)
        local days_left=$(( (expiry_epoch - now_epoch) / 86400 ))

        if (( days_left > 30 )); then
            echo -e "    ${GREEN}${CHECK}${NC} SSL is ${GREEN}active${NC} — expires in ${BOLD}${days_left} days${NC} (${expiry})"
        elif (( days_left > 7 )); then
            echo -e "    ${YELLOW}!${NC} SSL expires in ${YELLOW}${days_left} days${NC} (${expiry})"
        else
            echo -e "    ${RED}!${NC} SSL expires in ${RED}${days_left} days${NC} (${expiry})"
        fi
        echo

        if confirm "Force-renew the SSL certificate?"; then
            certbot renew --cert-name "$domain" --force-renewal 2>&1 | tee -a "$LOG_FILE" &
            spinner $! "Renewing SSL certificate..."
            systemctl reload nginx 2>/dev/null || true
            log "SSL certificate renewed for ${domain}"
        fi
    else
        # No SSL — offer to set up
        info "No SSL certificate found for ${domain}."
        if confirm "Set up SSL with Let's Encrypt?"; then
            echo -ne "  ${CYAN}${ARROW}${NC} Email for SSL: "
            read -r SSL_EMAIL
            validate_email "$SSL_EMAIL"
            certbot --nginx --non-interactive --agree-tos --email "$SSL_EMAIL" \
                --redirect -d "${domain}" -d "www.${domain}" 2>&1 | tee -a "$LOG_FILE" &
            spinner $! "Requesting SSL certificate..." || \
            certbot --nginx --non-interactive --agree-tos --email "$SSL_EMAIL" \
                --redirect -d "${domain}" 2>&1 | tee -a "$LOG_FILE" &
            spinner $! "Requesting SSL (without www)..." || \
            warn "SSL request failed. Try: sudo certbot --nginx -d ${domain}"
            systemctl reload nginx 2>/dev/null || true
            log "SSL setup complete for ${domain}"
        fi
    fi
}

# ── Regenerate Nginx Config ─────────────────────────────────
regenerate_nginx() {
    local domain="$1"
    local nginx_conf="${NGINX_SITES}/${domain}"
    local site_dir="${SITES_ROOT}/${domain}"
    local detected_type
    detected_type=$(detect_site_type "$domain")

    header "Regenerate Nginx Config: ${domain}"

    info "Detected site type: ${BOLD}${detected_type}${NC}"

    if [[ -f "$nginx_conf" ]]; then
        warn "This will overwrite the current nginx config for ${domain}."
        if ! confirm "Continue? (current config will be backed up)"; then
            return
        fi
        cp "$nginx_conf" "${site_dir}/backups/nginx-$(date +%Y%m%d%H%M%S).conf.bak" 2>/dev/null || true
        log "Current nginx config backed up"
    fi

    # Set up variables needed by create_nginx_config
    DOMAIN="$domain"
    SITE_DIR="$site_dir"
    SITE_TYPE="$detected_type"
    IS_LOCAL=false
    SETUP_SSL=false
    HANDLE_WWW=true

    # Check if local
    if grep -q "127\.0\.0\.1.*${domain}" /etc/hosts 2>/dev/null; then
        IS_LOCAL=true
        SETUP_SSL=false
    fi

    # Check if SSL cert exists
    if [[ -f "/etc/letsencrypt/live/${domain}/fullchain.pem" ]]; then
        SETUP_SSL=true
    fi

    # Get PHP socket if applicable
    if [[ "$detected_type" == "wordpress" || "$detected_type" == "php" ]]; then
        local pool_name="${domain//[.-]/_}"
        if [[ "$DISTRO_FAMILY" == "arch" ]]; then
            PHP_SOCK="/run/php-fpm/${pool_name}.sock"
        else
            PHP_SOCK="/run/php/${pool_name}.sock"
        fi
    fi

    # Get proxy port if applicable
    if [[ "$detected_type" == "proxy" ]]; then
        PROXY_PORT=$(grep -oP 'proxy_pass\s+http://127\.0\.0\.1:\K[0-9]+' "$nginx_conf" 2>/dev/null || echo "3000")
        echo -ne "  ${CYAN}${ARROW}${NC} Backend port ${DIM}[${PROXY_PORT}]${NC}: "
        read -r new_port
        [[ -n "$new_port" ]] && PROXY_PORT="$new_port"
    fi

    # Remove old config and symlink
    rm -f "${NGINX_ENABLED}/${domain}" "$nginx_conf"

    # Regenerate
    create_nginx_config

    log "Nginx config regenerated for ${domain}"
}

# ── Edit Site ────────────────────────────────────────────────
edit_site() {
    header "Edit a Site"
    pick_site "Site to edit" || { main_menu; return; }
    local EDIT_DOMAIN="$PICKED_DOMAIN"
    local site_type
    site_type=$(detect_site_type "$EDIT_DOMAIN")

    echo -e "  Editing: ${BOLD}${WHITE}${EDIT_DOMAIN}${NC} ${DIM}(${site_type})${NC}"
    echo

    # Build dynamic menu based on site type
    local -a menu_labels=()
    local -a menu_actions=()
    local n=1

    menu_labels+=("Rename domain")
    menu_actions+=("rename_domain")
    echo -e "    ${BOLD}${n}${NC} | Rename domain"
    (( n++ ))

    menu_labels+=("Manage SFTP users")
    menu_actions+=("manage_users")
    echo -e "    ${BOLD}${n}${NC} | Manage SFTP users"
    (( n++ ))

    if [[ "$site_type" == "wordpress" ]]; then
        menu_labels+=("Update WordPress")
        menu_actions+=("update_wordpress")
        echo -e "    ${BOLD}${n}${NC} | ${GREEN}Update WordPress${NC} ${DIM}-- core, plugins, themes${NC}"
        (( n++ ))
    fi

    if [[ "$site_type" == "wordpress" || "$site_type" == "php" ]]; then
        menu_labels+=("Update PHP extensions")
        menu_actions+=("update_php_extensions")
        echo -e "    ${BOLD}${n}${NC} | ${BLUE}Update PHP extensions${NC} ${DIM}-- imagick, redis, opcache${NC}"
        (( n++ ))
    fi

    menu_labels+=("Toggle SSL")
    menu_actions+=("toggle_ssl")
    echo -e "    ${BOLD}${n}${NC} | ${YELLOW}Toggle SSL${NC} ${DIM}-- setup or renew certificate${NC}"
    (( n++ ))

    menu_labels+=("Regenerate nginx config")
    menu_actions+=("regenerate_nginx")
    echo -e "    ${BOLD}${n}${NC} | ${MAGENTA}Regenerate nginx config${NC}"
    (( n++ ))

    menu_labels+=("Backup this site")
    menu_actions+=("backup_site")
    echo -e "    ${BOLD}${n}${NC} | ${WHITE}Backup this site${NC} ${DIM}-- files + database${NC}"
    (( n++ ))

    menu_labels+=("Back")
    menu_actions+=("back")
    echo -e "    ${DIM}${n}${NC} | Back"

    echo
    echo -ne "  ${CYAN}${ARROW}${NC} Choose ${DIM}[1-${n}]${NC}: "
    read -r edit_choice

    if [[ "$edit_choice" =~ ^[0-9]+$ ]] && (( edit_choice >= 1 && edit_choice <= n )); then
        local action="${menu_actions[$((edit_choice-1))]}"
        case "$action" in
            rename_domain)     rename_domain "$EDIT_DOMAIN" ;;
            manage_users)      manage_users "$EDIT_DOMAIN" ;;
            update_wordpress)  update_wordpress "$EDIT_DOMAIN" ;;
            update_php_extensions) update_php_extensions "$EDIT_DOMAIN" ;;
            toggle_ssl)        toggle_ssl "$EDIT_DOMAIN" ;;
            regenerate_nginx)  regenerate_nginx "$EDIT_DOMAIN" ;;
            backup_site)       backup_site "$EDIT_DOMAIN" ;;
            back)              main_menu ;;
        esac
    else
        warn "Invalid option."
        edit_site
    fi
}

# ── Rename Domain ────────────────────────────────────────────
rename_domain() {
    local OLD_DOMAIN="$1"
    local OLD_DIR="${SITES_ROOT}/${OLD_DOMAIN}"
    local OLD_NGINX="${NGINX_SITES}/${OLD_DOMAIN}"
    local OLD_POOL_NAME="${OLD_DOMAIN//[.-]/_}"

    header "Rename Domain: ${OLD_DOMAIN}"
    echo -ne "  ${CYAN}${ARROW}${NC} New domain name: "
    read -r NEW_DOMAIN
    [[ -z "$NEW_DOMAIN" ]] && warn "No domain entered." && return
    NEW_DOMAIN="${NEW_DOMAIN,,}"
    validate_domain "$NEW_DOMAIN"

    local NEW_DIR="${SITES_ROOT}/${NEW_DOMAIN}"
    [[ -d "$NEW_DIR" ]] && error "A site for ${NEW_DOMAIN} already exists."

    confirm "Rename ${BOLD}${OLD_DOMAIN}${NC} ${ARROW} ${BOLD}${NEW_DOMAIN}${NC}?" || return

    # Backup nginx config before changing
    if [[ -f "$OLD_NGINX" ]]; then
        cp "$OLD_NGINX" "${OLD_DIR}/backups/nginx-$(date +%Y%m%d%H%M%S).conf.bak"
        log "Nginx config backed up"
    fi

    # Move site directory
    mv "$OLD_DIR" "$NEW_DIR"
    log "Site directory moved to ${NEW_DIR}"

    # Update nginx config
    local NEW_NGINX="${NGINX_SITES}/${NEW_DOMAIN}"
    if [[ -f "$OLD_NGINX" ]]; then
        sed "s|${OLD_DOMAIN}|${NEW_DOMAIN}|g; s|${OLD_DIR}|${NEW_DIR}|g" "$OLD_NGINX" > "$NEW_NGINX"
        rm -f "$OLD_NGINX" "${NGINX_ENABLED}/${OLD_DOMAIN}"
        ln -sf "$NEW_NGINX" "${NGINX_ENABLED}/${NEW_DOMAIN}"
        log "Nginx config updated"
    else
        warn "No nginx config found for ${OLD_DOMAIN}."
    fi

    # Update PHP-FPM pool
    local OLD_POOL="${PHP_POOL_DIR}/${OLD_POOL_NAME}.conf"
    local NEW_POOL_NAME="${NEW_DOMAIN//[.-]/_}"
    local NEW_POOL="${PHP_POOL_DIR}/${NEW_POOL_NAME}.conf"
    if [[ -f "$OLD_POOL" ]]; then
        sed "s|${OLD_POOL_NAME}|${NEW_POOL_NAME}|g; s|${OLD_DIR}|${NEW_DIR}|g" "$OLD_POOL" > "$NEW_POOL"
        rm -f "$OLD_POOL"
        systemctl restart "${PHP_FPM_SERVICE}" 2>/dev/null || true
        log "PHP-FPM pool renamed"
    fi

    # Update WordPress if applicable
    local WP_CONF="${NEW_DIR}/public/wp-config.php"
    if [[ -f "$WP_CONF" ]]; then
        sed -i "s|${OLD_DOMAIN}|${NEW_DOMAIN}|g" "$WP_CONF" 2>/dev/null || true
        local DB_NAME="${OLD_DOMAIN//[.-]/_}"
        mysql -e "UPDATE \`${DB_NAME}\`.wp_options SET option_value='https://${NEW_DOMAIN}' WHERE option_name='siteurl';" 2>/dev/null || true
        mysql -e "UPDATE \`${DB_NAME}\`.wp_options SET option_value='https://${NEW_DOMAIN}' WHERE option_name='home';" 2>/dev/null || true
        warn "WordPress URLs updated. Run Certbot again if you had HTTPS."
    fi

    # Reload nginx
    if nginx -t 2>&1; then
        systemctl reload nginx
        log "Nginx reloaded"
    else
        error "Nginx config test failed after rename."
    fi

    # Update /etc/hosts if old domain was local
    if grep -q "127\.0\.0\.1.*${OLD_DOMAIN}" /etc/hosts 2>/dev/null; then
        remove_from_hosts "$OLD_DOMAIN"
        remove_from_hosts "www.${OLD_DOMAIN}"
        add_to_hosts "$NEW_DOMAIN"
        is_local_domain "$OLD_DOMAIN" || true
        log "Updated /etc/hosts: ${OLD_DOMAIN} -> ${NEW_DOMAIN}"
    fi

    # New SSL cert (skip for local domains)
    if ! is_local_domain "$NEW_DOMAIN"; then
        if confirm "Request a new SSL certificate for ${NEW_DOMAIN}?"; then
            echo -ne "  ${CYAN}${ARROW}${NC} Email for SSL: "
            read -r SSL_EMAIL
            validate_email "$SSL_EMAIL"
            certbot --nginx --non-interactive --agree-tos --email "$SSL_EMAIL" \
                --redirect -d "${NEW_DOMAIN}" -d "www.${NEW_DOMAIN}" 2>/dev/null || \
            certbot --nginx --non-interactive --agree-tos --email "$SSL_EMAIL" \
                --redirect -d "${NEW_DOMAIN}" 2>/dev/null || \
            warn "SSL request failed. Try manually: sudo certbot --nginx -d ${NEW_DOMAIN}"
        fi
    fi

    log "Domain renamed: ${OLD_DOMAIN} ${ARROW} ${NEW_DOMAIN}"
    if ! is_local_domain "$OLD_DOMAIN" && [[ -d "/etc/letsencrypt/live/${OLD_DOMAIN}" ]]; then
        info "Clean up old cert: ${DIM}sudo certbot delete --cert-name ${OLD_DOMAIN}${NC}"
    fi
}

# ── User Store Helpers ───────────────────────────────────────
users_dir() { echo "${SITES_ROOT}/$1/users"; }

list_site_users() {
    local DOMAIN="$1"
    local UDIR
    UDIR=$(users_dir "$DOMAIN")
    if [[ ! -d "$UDIR" ]] || [[ -z "$(ls -A "$UDIR" 2>/dev/null)" ]]; then
        warn "No SFTP users found for ${DOMAIN}."
        return 1
    fi
    echo
    echo -e "  ${BOLD}${WHITE}Users for ${DOMAIN}${NC}"
    separator
    local i=1
    for f in "$UDIR"/*.txt; do
        local uname
        uname=$(grep "Username:" "$f" | awk '{print $2}')
        local status="${RED}inactive${NC}"
        id "$uname" &>/dev/null && status="${GREEN}active${NC}"
        echo -e "    ${BOLD}${i}${NC} | ${uname}  [${status}]"
        (( i++ ))
    done
    separator
    echo
    return 0
}

pick_site_user() {
    local DOMAIN="$1"
    local UDIR
    UDIR=$(users_dir "$DOMAIN")
    local files=("$UDIR"/*.txt)
    [[ ! -e "${files[0]}" ]] && warn "No users found." && return 1

    list_site_users "$DOMAIN"
    echo -ne "  ${CYAN}${ARROW}${NC} Enter number or username: "
    read -r PICK_INPUT
    [[ -z "$PICK_INPUT" ]] && return 1

    if [[ "$PICK_INPUT" =~ ^[0-9]+$ ]]; then
        local i=1
        for f in "$UDIR"/*.txt; do
            if [[ "$i" -eq "$PICK_INPUT" ]]; then
                PICKED_USER=$(grep "Username:" "$f" | awk '{print $2}')
                PICKED_USER_FILE="$f"
                return 0
            fi
            (( i++ ))
        done
        warn "No user with number ${PICK_INPUT}."
        return 1
    fi

    PICKED_USER="$PICK_INPUT"
    PICKED_USER_FILE="${UDIR}/${PICKED_USER}.txt"
    [[ ! -f "$PICKED_USER_FILE" ]] && warn "User ${PICKED_USER} not found." && return 1
    return 0
}

save_user_record() {
    local DOMAIN="$1" USER="$2" SITE_D="$3"
    local UDIR
    UDIR=$(users_dir "$DOMAIN")
    mkdir -p "$UDIR"
    chmod 700 "$UDIR"
    cat > "${UDIR}/${USER}.txt" <<EOF
Username:   ${USER}
Domain:     ${DOMAIN}
Jail root:  ${SITE_D}
Upload dir: ${SITE_D}/public
Access:     SFTP only (chroot jailed)
Created:    $(date)

FileZilla settings:
  Protocol:  SFTP
  Host:      YOUR_SERVER_IP
  Port:      22
  User:      ${USER}
  Password:  (as set)
  Default remote dir: /public
EOF
    chmod 600 "${UDIR}/${USER}.txt"
}

# ── Manage Users Menu ────────────────────────────────────────
manage_users() {
    local DOMAIN="$1"
    local SITE_DIR="${SITES_ROOT}/${DOMAIN}"

    # Migrate legacy single-user file
    if [[ -f "${SITE_DIR}/access-user.txt" ]] && [[ ! -d "$(users_dir "$DOMAIN")" ]]; then
        local OLD_USER
        OLD_USER=$(grep "Username:" "${SITE_DIR}/access-user.txt" | awk '{print $2}')
        if [[ -n "$OLD_USER" ]]; then
            save_user_record "$DOMAIN" "$OLD_USER" "$SITE_DIR"
            rm -f "${SITE_DIR}/access-user.txt"
            log "Migrated user ${OLD_USER} to new store"
        fi
    fi

    header "Manage SFTP Users - ${DOMAIN}"
    list_site_users "$DOMAIN" || true

    echo -e "    ${BOLD}${GREEN}1${NC} | Add a new user"
    echo -e "    ${BOLD}${CYAN}2${NC} | Change password"
    echo -e "    ${BOLD}${YELLOW}3${NC} | Rename a user"
    echo -e "    ${BOLD}${RED}4${NC} | Delete a user"
    echo -e "    ${DIM}5${NC} | Back"
    echo
    echo -ne "  ${CYAN}${ARROW}${NC} Choose ${DIM}[1-5]${NC}: "
    read -r mu_choice

    case "$mu_choice" in
        1) add_site_user "$DOMAIN" ;;
        2) change_user_password "$DOMAIN" ;;
        3) rename_site_user "$DOMAIN" ;;
        4) delete_site_user "$DOMAIN" ;;
        5) return ;;
        *) warn "Invalid option."; manage_users "$DOMAIN" ;;
    esac
}

# ── Add User ─────────────────────────────────────────────────
add_site_user() {
    local DOMAIN="$1"
    local SITE_DIR="${SITES_ROOT}/${DOMAIN}"

    header "Add SFTP User - ${DOMAIN}"

    echo -ne "  ${CYAN}${ARROW}${NC} New username: "
    read -r ACCESS_USER
    [[ -z "$ACCESS_USER" ]] && warn "No username entered." && return
    validate_username "$ACCESS_USER"

    if id "$ACCESS_USER" &>/dev/null; then
        warn "System user ${ACCESS_USER} already exists."
        confirm "Add them to this site anyway?" || return
    else
        useradd -M -s ${NOLOGIN_SHELL} "$ACCESS_USER"
        log "System user ${ACCESS_USER} created"
    fi

    passwd "$ACCESS_USER"
    usermod -aG ${WEB_USER} "$ACCESS_USER"

    # Ensure internal-sftp subsystem (handle tabs/spaces in existing config)
    if ! grep -qP '^Subsystem\s+sftp\s+internal-sftp' /etc/ssh/sshd_config; then
        if grep -qP '^Subsystem\s+sftp' /etc/ssh/sshd_config; then
            sed -i -E 's|^Subsystem[[:space:]]+sftp[[:space:]]+.*|Subsystem sftp internal-sftp|' /etc/ssh/sshd_config
        else
            echo "Subsystem sftp internal-sftp" >> /etc/ssh/sshd_config
        fi
        log "sshd: Subsystem sftp set to internal-sftp"
    fi

    # Chroot permissions
    chown root:root "${SITES_ROOT}" "$SITE_DIR"
    chmod 755 "${SITES_ROOT}" "$SITE_DIR"
    chown -R "${ACCESS_USER}:${WEB_USER}" "${SITE_DIR}/public"
    chmod -R 775 "${SITE_DIR}/public"
    find "${SITE_DIR}/public" -type d -exec chmod g+s {} \;
    chmod o+x "/home/${REAL_USER}" 2>/dev/null || true

    # WordPress fix: keep wp-content writable by ${WEB_USER}
    if [[ -d "${SITE_DIR}/public/wp-content" ]]; then
        chown -R ${WEB_USER}:${WEB_USER} "${SITE_DIR}/public/wp-content"
        chmod -R 775 "${SITE_DIR}/public/wp-content"
        find "${SITE_DIR}/public/wp-content" -type d -exec chmod g+s {} \;
        if [[ -f "${SITE_DIR}/public/wp-config.php" ]] && ! grep -q "FS_METHOD" "${SITE_DIR}/public/wp-config.php"; then
            sed -i "/table_prefix/a\\
\\
/** Force direct filesystem writes (no FTP prompt) */\\
define('FS_METHOD', 'direct');" "${SITE_DIR}/public/wp-config.php"
        fi
        log "WordPress wp-content ownership preserved for ${WEB_USER}"
    fi

    # sshd_config Match User block
    if grep -q "Match User ${ACCESS_USER}" /etc/ssh/sshd_config; then
        warn "Removing old sshd entry for ${ACCESS_USER}."
        sed -i "/# SFTP jail.*${ACCESS_USER}/,+5d" /etc/ssh/sshd_config
        sed -i "/Match User ${ACCESS_USER}/,+4d" /etc/ssh/sshd_config
    fi

    cat >> /etc/ssh/sshd_config <<EOF

# SFTP jail for ${DOMAIN} — managed by setup-site.sh
Match User ${ACCESS_USER}
    ChrootDirectory ${SITE_DIR}
    ForceCommand internal-sftp -d /public
    AllowTcpForwarding no
    X11Forwarding no
    PasswordAuthentication yes
EOF

    if sshd -t 2>/dev/null; then
        systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null
        log "sshd restarted — chroot jail active for ${ACCESS_USER}"
    else
        error "sshd config test failed. Check /etc/ssh/sshd_config"
    fi

    save_user_record "$DOMAIN" "$ACCESS_USER" "$SITE_DIR"

    echo
    echo -e "  ${GREEN}${BOLD}SFTP User Ready${NC}"
    separator
    echo -e "    ${BOLD}Username${NC}    | ${ACCESS_USER}"
    echo -e "    ${BOLD}Jailed to${NC}   | ${SITE_DIR}/public"
    echo -e "    ${BOLD}FileZilla${NC}   | SFTP / port 22 / ${ACCESS_USER}"
    separator
    echo
}

# ── Change Password ──────────────────────────────────────────
change_user_password() {
    local DOMAIN="$1"
    header "Change User Password - ${DOMAIN}"

    pick_site_user "$DOMAIN" || return

    if ! id "$PICKED_USER" &>/dev/null; then
        error "System user ${PICKED_USER} does not exist."
    fi

    info "Setting new password for ${BOLD}${PICKED_USER}${NC}..."
    passwd "$PICKED_USER"
    log "Password updated for ${PICKED_USER}"
}

# ── Rename User ──────────────────────────────────────────────
rename_site_user() {
    local DOMAIN="$1"
    local SITE_DIR="${SITES_ROOT}/${DOMAIN}"
    header "Rename SFTP User - ${DOMAIN}"

    pick_site_user "$DOMAIN" || return
    local OLD_USER="$PICKED_USER"

    echo -ne "  ${CYAN}${ARROW}${NC} New username: "
    read -r NEW_USER
    [[ -z "$NEW_USER" ]] && warn "No username entered." && return
    validate_username "$NEW_USER"

    if id "$NEW_USER" &>/dev/null; then
        error "User ${NEW_USER} already exists on this system."
    fi

    confirm "Rename ${BOLD}${OLD_USER}${NC} ${ARROW} ${BOLD}${NEW_USER}${NC}?" || return

    usermod -l "$NEW_USER" "$OLD_USER"
    usermod -s ${NOLOGIN_SHELL} "$NEW_USER" 2>/dev/null || true

    # Update sshd_config
    if grep -q "Match User ${OLD_USER}" /etc/ssh/sshd_config; then
        sed -i "s/Match User ${OLD_USER}/Match User ${NEW_USER}/" /etc/ssh/sshd_config
        if sshd -t 2>/dev/null; then
            systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null
            log "sshd updated for ${NEW_USER}"
        else
            warn "sshd config error. Check /etc/ssh/sshd_config"
        fi
    fi

    # Fix permissions
    chown root:root "${SITES_ROOT}" "$SITE_DIR"
    chmod 755 "${SITES_ROOT}" "$SITE_DIR"
    chown -R "${NEW_USER}:${WEB_USER}" "${SITE_DIR}/public"
    chmod -R 775 "${SITE_DIR}/public"

    # WordPress fix: keep wp-content writable by ${WEB_USER}
    if [[ -d "${SITE_DIR}/public/wp-content" ]]; then
        chown -R ${WEB_USER}:${WEB_USER} "${SITE_DIR}/public/wp-content"
        chmod -R 775 "${SITE_DIR}/public/wp-content"
        find "${SITE_DIR}/public/wp-content" -type d -exec chmod g+s {} \;
    fi

    # Update record file
    local UDIR
    UDIR=$(users_dir "$DOMAIN")
    mv "${UDIR}/${OLD_USER}.txt" "${UDIR}/${NEW_USER}.txt" 2>/dev/null || true
    sed -i "s/Username:.*${OLD_USER}/Username:   ${NEW_USER}/" "${UDIR}/${NEW_USER}.txt" 2>/dev/null || true

    log "User renamed: ${OLD_USER} ${ARROW} ${NEW_USER}"
    info "Set a new password for ${NEW_USER}:"
    passwd "$NEW_USER"
}

# ── Delete User ──────────────────────────────────────────────
delete_site_user() {
    local DOMAIN="$1"
    local SITE_DIR="${SITES_ROOT}/${DOMAIN}"
    header "Delete SFTP User - ${DOMAIN}"

    pick_site_user "$DOMAIN" || return
    local DEL_USER="$PICKED_USER"

    confirm "${RED}Delete user ${BOLD}${DEL_USER}${NC}${RED}? This removes system account and SFTP access.${NC}" || return

    # Remove sshd_config block
    if grep -q "Match User ${DEL_USER}" /etc/ssh/sshd_config; then
        sed -i "/# SFTP jail.*${DEL_USER}/,+5d" /etc/ssh/sshd_config
        sed -i "/Match User ${DEL_USER}/,+4d" /etc/ssh/sshd_config
        if sshd -t 2>/dev/null; then
            systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null
            log "sshd: removed jail entry for ${DEL_USER}"
        else
            warn "sshd config error after removal. Check /etc/ssh/sshd_config"
        fi
    fi

    if id "$DEL_USER" &>/dev/null; then
        userdel "$DEL_USER"
        log "System user ${DEL_USER} deleted"
    else
        warn "System user ${DEL_USER} not found (may already be removed)."
    fi

    chown -R ${WEB_USER}:${WEB_USER} "${SITE_DIR}/public" 2>/dev/null || true

    local UDIR
    UDIR=$(users_dir "$DOMAIN")
    rm -f "${UDIR}/${DEL_USER}.txt"
    log "User ${DEL_USER} fully removed from ${DOMAIN}"
}

# ── Delete Site ──────────────────────────────────────────────
delete_site() {
    header "Delete a Site"
    pick_site "Site to delete" || return
    local DEL_DOMAIN="$PICKED_DOMAIN"
    local DEL_DIR="${SITES_ROOT}/${DEL_DOMAIN}"

    echo -e "\n  ${RED}${BOLD}WARNING: This action is destructive and cannot be undone.${NC}\n"
    confirm "${RED}Are you SURE you want to delete ${BOLD}${DEL_DOMAIN}${NC}${RED}?${NC}" || return

    # Offer backup before deletion
    if confirm "Create a backup of ${DEL_DOMAIN} before deleting?"; then
        local backup_file="/home/${REAL_USER}/backup-${DEL_DOMAIN}-$(date +%Y%m%d%H%M%S).tar.gz"
        info "Creating backup..."
        tar -czf "$backup_file" -C "${SITES_ROOT}" "${DEL_DOMAIN}" 2>/dev/null &
        spinner $! "Backing up ${DEL_DOMAIN}..."
        chown "${REAL_USER}:${REAL_USER}" "$backup_file"
        log "Backup saved to ${backup_file}"
    fi

    # Remove SFTP users for this site
    local UDIR="${DEL_DIR}/users"
    if [[ -d "$UDIR" ]] && [[ -n "$(ls -A "$UDIR" 2>/dev/null)" ]]; then
        info "Removing SFTP users..."
        for f in "$UDIR"/*.txt; do
            local uname
            uname=$(grep "Username:" "$f" | awk '{print $2}')
            if [[ -n "$uname" ]]; then
                # Remove sshd config
                sed -i "/# SFTP jail.*${uname}/,+5d" /etc/ssh/sshd_config 2>/dev/null
                sed -i "/Match User ${uname}/,+4d" /etc/ssh/sshd_config 2>/dev/null
                # Remove system user
                userdel "$uname" 2>/dev/null && log "Removed user ${uname}" || true
            fi
        done
        sshd -t 2>/dev/null && systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null 2>/dev/null || true
    fi

    # Remove nginx
    rm -f "${NGINX_ENABLED}/${DEL_DOMAIN}" "${NGINX_SITES}/${DEL_DOMAIN}"
    if nginx -t 2>&1 >/dev/null; then
        systemctl reload nginx
        log "Nginx config removed"
    fi

    # Remove PHP pool
    local POOL_NAME="${DEL_DOMAIN//[.-]/_}"
    rm -f "${PHP_POOL_DIR}/${POOL_NAME}.conf" 2>/dev/null
    systemctl restart "${PHP_FPM_SERVICE}" 2>/dev/null || true

    # Remove site files
    if confirm "Delete site files at ${DEL_DIR}?"; then
        rm -rf "$DEL_DIR"
        log "Site files deleted"
    fi

    # Remove database
    if confirm "Drop the database for ${DEL_DOMAIN} (if it exists)?"; then
        local DB_NAME="${DEL_DOMAIN//[.-]/_}"
        local DB_USER="${DB_NAME:0:16}_usr"
        mysql -e "DROP DATABASE IF EXISTS \`${DB_NAME}\`;" 2>/dev/null
        mysql -e "DROP USER IF EXISTS '${DB_USER}'@'localhost';" 2>/dev/null
        mysql -e "FLUSH PRIVILEGES;" 2>/dev/null
        log "Database ${DB_NAME} dropped"
    fi

    # Remove SSL cert
    if [[ -d "/etc/letsencrypt/live/${DEL_DOMAIN}" ]]; then
        if confirm "Remove SSL certificate for ${DEL_DOMAIN}?"; then
            certbot delete --cert-name "${DEL_DOMAIN}" --non-interactive 2>/dev/null || true
            log "SSL certificate removed"
        fi
    fi

    # Remove from /etc/hosts if it was a local domain
    if grep -q "127\.0\.0\.1.*${DEL_DOMAIN}" /etc/hosts 2>/dev/null; then
        remove_from_hosts "$DEL_DOMAIN"
        remove_from_hosts "www.${DEL_DOMAIN}"
    fi

    echo
    log "${BOLD}Site ${DEL_DOMAIN} has been deleted.${NC}"
}

# ── Backup System ────────────────────────────────────────────
backup_site() {
    local domain="$1"
    local site_dir="${SITES_ROOT}/${domain}"
    local site_type
    site_type=$(detect_site_type "$domain")
    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    local backup_dir="${BACKUP_ROOT}/${domain}"
    local backup_file="${backup_dir}/backup-${domain}-${timestamp}.tar.gz"

    mkdir -p "$backup_dir"

    header "Backup: ${domain} (${site_type})"

    # Step 1: Database dump (if WordPress or PHP with DB)
    local db_dump=""
    if [[ -f "${site_dir}/db-credentials.txt" ]]; then
        local db_name db_user db_pass
        db_name=$(grep "DB Name:" "${site_dir}/db-credentials.txt" 2>/dev/null | awk '{print $NF}')
        db_user=$(grep "DB User:" "${site_dir}/db-credentials.txt" 2>/dev/null | awk '{print $NF}')
        db_pass=$(grep "DB Pass:" "${site_dir}/db-credentials.txt" 2>/dev/null | awk '{print $NF}')

        if [[ -n "$db_name" ]] && command -v mysqldump &>/dev/null; then
            db_dump="${site_dir}/backups/db-${timestamp}.sql"
            info "Dumping database ${BOLD}${db_name}${NC}..."
            if mysqldump --single-transaction -u"${db_user}" -p"${db_pass}" "${db_name}" > "$db_dump" 2>/dev/null; then
                local dump_size
                dump_size=$(du -sh "$db_dump" 2>/dev/null | awk '{print $1}')
                log "Database dumped (${dump_size}): ${db_dump}"
            else
                warn "Database dump failed — backing up files only."
                rm -f "$db_dump"
                db_dump=""
            fi
        fi
    fi

    # Step 2: Tar the entire site directory
    info "Compressing site files..."
    tar -czf "$backup_file" -C "${SITES_ROOT}" "${domain}" 2>/dev/null &
    spinner $! "Creating backup archive..."

    # Clean up temporary DB dump (it's inside the tar now)
    [[ -n "$db_dump" ]] && rm -f "$db_dump"

    if [[ -f "$backup_file" ]]; then
        local backup_size
        backup_size=$(du -sh "$backup_file" 2>/dev/null | awk '{print $1}')
        chown "${REAL_USER}:${REAL_USER}" "$backup_file"
        log "Backup complete: ${backup_file} (${backup_size})"

        # Step 3: Enforce retention policy
        cleanup_old_backups "$domain"

        # Step 4: Remote sync if configured
        sync_backup_remote "$backup_file"

        echo
        echo -e "  ${GREEN}${BOLD}Backup Successful${NC}"
        separator
        echo -e "    ${BOLD}File${NC}   | ${backup_file}"
        echo -e "    ${BOLD}Size${NC}   | ${backup_size}"
        [[ -n "$db_dump" ]] && echo -e "    ${BOLD}DB${NC}     | ${db_name} (included)"
        separator
    else
        warn "Backup file was not created. Check disk space."
    fi
}

cleanup_old_backups() {
    local domain="$1"
    local backup_dir="${BACKUP_ROOT}/${domain}"
    local count
    count=$(find "$backup_dir" -name "backup-${domain}-*.tar.gz" -type f 2>/dev/null | wc -l)

    if (( count > BACKUP_RETENTION )); then
        local to_delete=$(( count - BACKUP_RETENTION ))
        info "Cleaning up: removing ${to_delete} old backup(s) (keeping ${BACKUP_RETENTION})..."
        find "$backup_dir" -name "backup-${domain}-*.tar.gz" -type f -printf '%T@ %p\n' \
            | sort -n | head -n "$to_delete" | awk '{print $2}' \
            | while read -r old_backup; do
                rm -f "$old_backup"
                log "Removed old backup: $(basename "$old_backup")"
            done
    fi
}

restore_site() {
    local domain="$1"
    local site_dir="${SITES_ROOT}/${domain}"
    local backup_dir="${BACKUP_ROOT}/${domain}"
    local site_type
    site_type=$(detect_site_type "$domain")

    header "Restore: ${domain}"

    # List available backups
    if [[ ! -d "$backup_dir" ]] || [[ -z "$(ls -A "$backup_dir" 2>/dev/null)" ]]; then
        warn "No backups found for ${domain}."
        return 1
    fi

    echo -e "  ${BOLD}Available backups:${NC}"
    echo
    local i=1
    local -a backup_files=()
    while IFS= read -r bfile; do
        local bname bsize bdate
        bname=$(basename "$bfile")
        bsize=$(du -sh "$bfile" 2>/dev/null | awk '{print $1}')
        # Extract date from filename: backup-domain-YYYYMMDD-HHMMSS.tar.gz
        bdate=$(echo "$bname" | grep -oP '\d{8}-\d{6}' | sed 's/\([0-9]\{4\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)-\([0-9]\{2\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)/\1-\2-\3 \4:\5:\6/')
        backup_files+=("$bfile")
        echo -e "    ${BOLD}${i}${NC} | ${bdate} (${bsize})"
        (( i++ ))
    done < <(find "$backup_dir" -name "backup-${domain}-*.tar.gz" -type f | sort -r)

    if [[ ${#backup_files[@]} -eq 0 ]]; then
        warn "No backup archives found."
        return 1
    fi

    echo
    echo -ne "  ${CYAN}${ARROW}${NC} Select backup to restore ${DIM}[1-${#backup_files[@]}]${NC}: "
    read -r restore_choice

    if ! [[ "$restore_choice" =~ ^[0-9]+$ ]] || (( restore_choice < 1 || restore_choice > ${#backup_files[@]} )); then
        warn "Invalid selection."
        return 1
    fi

    local selected_backup="${backup_files[$((restore_choice-1))]}"
    echo
    warn "This will ${BOLD}overwrite${NC} the current site files for ${BOLD}${domain}${NC}."
    warn "The current state will be lost unless you backup first."
    if ! confirm "Restore ${domain} from $(basename "$selected_backup")?"; then
        return
    fi

    # Offer to backup current state first
    if confirm "Create a backup of the current state before restoring?"; then
        backup_site "$domain"
    fi

    info "Restoring ${domain}..."

    # Stop PHP-FPM if applicable
    if [[ "$site_type" == "wordpress" || "$site_type" == "php" ]]; then
        systemctl stop "${PHP_FPM_SERVICE}" 2>/dev/null || true
    fi

    # Extract backup over site directory
    tar -xzf "$selected_backup" -C "${SITES_ROOT}" 2>/dev/null &
    spinner $! "Extracting backup..."

    # Restore database if dump exists in backup
    if [[ -f "${site_dir}/db-credentials.txt" ]]; then
        local db_name db_user db_pass
        db_name=$(grep "DB Name:" "${site_dir}/db-credentials.txt" 2>/dev/null | awk '{print $NF}')
        db_user=$(grep "DB User:" "${site_dir}/db-credentials.txt" 2>/dev/null | awk '{print $NF}')
        db_pass=$(grep "DB Pass:" "${site_dir}/db-credentials.txt" 2>/dev/null | awk '{print $NF}')

        # Find the most recent DB dump inside the restored backup
        local latest_dump
        latest_dump=$(find "${site_dir}/backups" -name "db-*.sql" -type f 2>/dev/null | sort -r | head -1)

        if [[ -n "$latest_dump" ]] && [[ -n "$db_name" ]]; then
            info "Restoring database ${BOLD}${db_name}${NC}..."
            if mysql -u"${db_user}" -p"${db_pass}" "${db_name}" < "$latest_dump" 2>/dev/null; then
                log "Database restored from $(basename "$latest_dump")"
                rm -f "$latest_dump"
            else
                warn "Database restore failed. You may need to restore manually."
            fi
        fi
    fi

    # Fix permissions
    chown root:root "${site_dir}" 2>/dev/null || true
    chmod 755 "${site_dir}" 2>/dev/null || true
    chown -R "${WEB_USER}:${WEB_USER}" "${site_dir}/public" 2>/dev/null || true
    chown "${REAL_USER}:${REAL_USER}" "${site_dir}/db-credentials.txt" 2>/dev/null || true

    # Restart services
    if [[ "$site_type" == "wordpress" || "$site_type" == "php" ]]; then
        systemctl start "${PHP_FPM_SERVICE}" 2>/dev/null || true
    fi
    systemctl reload nginx 2>/dev/null || true

    echo
    log "Site ${domain} restored successfully from $(basename "$selected_backup")"
}

backup_all_sites() {
    header "Backup All Sites"

    if [[ ! -d "$SITES_ROOT" ]] || [[ -z "$(ls -A "$SITES_ROOT" 2>/dev/null)" ]]; then
        warn "No sites found."
        return
    fi

    local site_count=0
    for dir in "${SITES_ROOT}"/*/; do
        [[ -d "$dir" ]] || continue
        (( site_count++ ))
    done

    info "Found ${BOLD}${site_count}${NC} site(s) to backup."
    confirm "Backup all ${site_count} sites?" || return

    local success=0 failed=0
    for dir in "${SITES_ROOT}"/*/; do
        [[ -d "$dir" ]] || continue
        local domain
        domain=$(basename "$dir")
        echo
        if backup_site "$domain"; then
            (( success++ ))
        else
            (( failed++ ))
        fi
    done

    echo
    separator
    log "Backup complete: ${GREEN}${success} succeeded${NC}, ${RED}${failed} failed${NC}"
}

list_backups() {
    header "Available Backups"

    if [[ ! -d "$BACKUP_ROOT" ]] || [[ -z "$(ls -A "$BACKUP_ROOT" 2>/dev/null)" ]]; then
        warn "No backups found."
        return
    fi

    local total_size
    total_size=$(du -sh "$BACKUP_ROOT" 2>/dev/null | awk '{print $1}')
    info "Backup directory: ${BACKUP_ROOT} (${BOLD}${total_size}${NC} total)"
    echo

    for domain_dir in "${BACKUP_ROOT}"/*/; do
        [[ -d "$domain_dir" ]] || continue
        local domain
        domain=$(basename "$domain_dir")
        local count dir_size
        count=$(find "$domain_dir" -name "backup-*.tar.gz" -type f 2>/dev/null | wc -l)
        dir_size=$(du -sh "$domain_dir" 2>/dev/null | awk '{print $1}')

        echo -e "  ${BOLD}${WHITE}${domain}${NC} ${DIM}(${count} backup(s), ${dir_size})${NC}"

        find "$domain_dir" -name "backup-*.tar.gz" -type f -printf '%T@ %p\n' 2>/dev/null \
            | sort -rn | while read -r ts bfile; do
                local bname bsize bdate
                bname=$(basename "$bfile")
                bsize=$(du -sh "$bfile" 2>/dev/null | awk '{print $1}')
                bdate=$(echo "$bname" | grep -oP '\d{8}-\d{6}' | sed 's/\([0-9]\{4\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)-\([0-9]\{2\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)/\1-\2-\3 \4:\5:\6/')
                echo -e "    ${DIM}-${NC} ${bdate}  ${bsize}  ${DIM}${bname}${NC}"
            done
        echo
    done
}

setup_backup_schedule() {
    header "Automatic Backup Schedule"

    # Check if already configured
    if systemctl list-timers --all 2>/dev/null | grep -q "websetup-backup"; then
        info "Auto-backup is already configured."
        systemctl list-timers websetup-backup.timer 2>/dev/null
        echo
        if ! confirm "Reconfigure the backup schedule?"; then
            return
        fi
    fi

    echo -e "  ${BOLD}Backup frequency:${NC}"
    echo
    echo -e "    ${BOLD}1${NC} | Daily at 3:00 AM"
    echo -e "    ${BOLD}2${NC} | Every 12 hours"
    echo -e "    ${BOLD}3${NC} | Weekly (Sunday 3:00 AM)"
    echo
    echo -ne "  ${CYAN}${ARROW}${NC} Choose ${DIM}[1-3]${NC}: "
    read -r sched_choice

    local on_calendar
    case "$sched_choice" in
        1) on_calendar="*-*-* 03:00:00" ;;
        2) on_calendar="*-*-* 00,12:00:00" ;;
        3) on_calendar="Sun *-*-* 03:00:00" ;;
        *) on_calendar="*-*-* 03:00:00" ;;
    esac

    # Ask for retention
    echo -ne "  ${CYAN}${ARROW}${NC} Keep last how many backups per site? ${DIM}[${BACKUP_RETENTION}]${NC}: "
    read -r ret_input
    [[ -n "$ret_input" ]] && BACKUP_RETENTION="$ret_input"

    # Create the backup script
    info "Creating backup script..."
    cat > /usr/local/bin/websetup-backup.sh <<BSCRIPT
#!/bin/bash
# Auto-generated by setup-site.sh — do not edit manually
REAL_USER="${REAL_USER}"
SITES_ROOT="${SITES_ROOT}"
BACKUP_ROOT="${BACKUP_ROOT}"
BACKUP_RETENTION=${BACKUP_RETENTION}
BACKUP_REMOTE_CONF="${BACKUP_REMOTE_CONF}"
LOG="/var/log/websetup-backup.log"
WEB_USER="${WEB_USER}"

log() { echo "\$(date '+%Y-%m-%d %H:%M:%S') \$*" >> "\$LOG"; }

cleanup_old() {
    local domain="\$1" backup_dir="\${BACKUP_ROOT}/\${domain}"
    local count
    count=\$(find "\$backup_dir" -name "backup-\${domain}-*.tar.gz" -type f 2>/dev/null | wc -l)
    if (( count > BACKUP_RETENTION )); then
        local to_delete=\$(( count - BACKUP_RETENTION ))
        find "\$backup_dir" -name "backup-\${domain}-*.tar.gz" -type f -printf '%T@ %p\n' \\
            | sort -n | head -n "\$to_delete" | awk '{print \$2}' \\
            | while read -r old; do rm -f "\$old"; log "Removed old: \$(basename "\$old")"; done
    fi
}

sync_remote() {
    local backup_file="\$1"
    [[ -f "\$BACKUP_REMOTE_CONF" ]] || return 0
    source "\$BACKUP_REMOTE_CONF"
    case "\$REMOTE_TYPE" in
        rclone)
            if command -v rclone &>/dev/null; then
                rclone copy "\$backup_file" "\$REMOTE_DEST" 2>>"\$LOG" && log "Synced to remote: \$(basename "\$backup_file")"
            fi
            ;;
        rsync)
            if command -v rsync &>/dev/null; then
                rsync -az "\$backup_file" "\$REMOTE_DEST" 2>>"\$LOG" && log "Synced to remote: \$(basename "\$backup_file")"
            fi
            ;;
    esac
}

log "=== Backup started ==="

for site_dir in "\${SITES_ROOT}"/*/; do
    [[ -d "\$site_dir" ]] || continue
    domain=\$(basename "\$site_dir")
    timestamp=\$(date +%Y%m%d-%H%M%S)
    backup_dir="\${BACKUP_ROOT}/\${domain}"
    backup_file="\${backup_dir}/backup-\${domain}-\${timestamp}.tar.gz"
    mkdir -p "\$backup_dir"

    # Database dump
    if [[ -f "\${site_dir}/db-credentials.txt" ]]; then
        db_name=\$(grep "DB Name:" "\${site_dir}/db-credentials.txt" | awk '{print \$NF}')
        db_user=\$(grep "DB User:" "\${site_dir}/db-credentials.txt" | awk '{print \$NF}')
        db_pass=\$(grep "DB Pass:" "\${site_dir}/db-credentials.txt" | awk '{print \$NF}')
        if [[ -n "\$db_name" ]] && command -v mysqldump &>/dev/null; then
            mkdir -p "\${site_dir}/backups"
            mysqldump --single-transaction -u"\${db_user}" -p"\${db_pass}" "\${db_name}" > "\${site_dir}/backups/db-\${timestamp}.sql" 2>/dev/null
            log "DB dump: \${db_name}"
        fi
    fi

    # Tar site
    tar -czf "\$backup_file" -C "\${SITES_ROOT}" "\${domain}" 2>/dev/null
    chown "\${REAL_USER}:\${REAL_USER}" "\$backup_file" 2>/dev/null

    # Cleanup temp DB dump
    rm -f "\${site_dir}/backups/db-\${timestamp}.sql" 2>/dev/null

    size=\$(du -sh "\$backup_file" 2>/dev/null | awk '{print \$1}')
    log "Backed up: \${domain} (\${size})"

    cleanup_old "\$domain"
    sync_remote "\$backup_file"
done

log "=== Backup finished ==="
BSCRIPT
    chmod +x /usr/local/bin/websetup-backup.sh
    log "Backup script created: /usr/local/bin/websetup-backup.sh"

    # Create systemd service
    cat > /etc/systemd/system/websetup-backup.service <<EOF
[Unit]
Description=Web Setup - Automatic Site Backups
After=network-online.target mysql.service mariadb.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/websetup-backup.sh
Nice=10
IOSchedulingClass=idle
EOF
    log "Systemd service created"

    # Create systemd timer
    cat > /etc/systemd/system/websetup-backup.timer <<EOF
[Unit]
Description=Web Setup - Scheduled backup timer

[Timer]
OnCalendar=${on_calendar}
RandomizedDelaySec=900
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now websetup-backup.timer
    log "Backup timer enabled"

    echo
    echo -e "  ${GREEN}${BOLD}Auto-Backup Configured${NC}"
    separator
    echo -e "    ${BOLD}Schedule${NC}    | ${on_calendar}"
    echo -e "    ${BOLD}Retention${NC}   | Keep last ${BACKUP_RETENTION} per site"
    echo -e "    ${BOLD}Script${NC}      | /usr/local/bin/websetup-backup.sh"
    echo -e "    ${BOLD}Log${NC}         | /var/log/websetup-backup.log"
    separator
    echo
    systemctl list-timers websetup-backup.timer 2>/dev/null
}

setup_remote_sync() {
    header "Remote Backup Sync"

    if [[ -f "$BACKUP_REMOTE_CONF" ]]; then
        source "$BACKUP_REMOTE_CONF"
        info "Current remote config: ${BOLD}${REMOTE_TYPE}${NC} -> ${REMOTE_DEST}"
        echo
        if ! confirm "Reconfigure remote sync?"; then
            return
        fi
    fi

    echo -e "  ${BOLD}Remote backup method:${NC}"
    echo
    echo -e "    ${BOLD}1${NC} | ${BOLD}rclone${NC}   ${DIM}-- S3, Backblaze B2, Google Drive, etc.${NC}"
    echo -e "    ${BOLD}2${NC} | ${BOLD}rsync${NC}    ${DIM}-- Remote server via SSH${NC}"
    echo -e "    ${BOLD}3${NC} | ${RED}Remove${NC}   ${DIM}-- Disable remote sync${NC}"
    echo
    echo -ne "  ${CYAN}${ARROW}${NC} Choose ${DIM}[1-3]${NC}: "
    read -r remote_choice

    case "$remote_choice" in
        1)
            # rclone setup
            if ! command -v rclone &>/dev/null; then
                info "rclone not found. Installing..."
                if [[ "$DISTRO_FAMILY" == "arch" ]]; then
                    pkg_install rclone &
                    spinner $! "Installing rclone..."
                else
                    DEBIAN_FRONTEND=noninteractive apt install -y rclone 2>&1 | tee -a "$LOG_FILE" &
                    spinner $! "Installing rclone..."
                fi
            fi

            if ! command -v rclone &>/dev/null; then
                warn "rclone installation failed. Install manually: https://rclone.org/install/"
                return 1
            fi

            info "Run ${BOLD}rclone config${NC} to set up your remote (if not already done)."
            if confirm "Open rclone config now?"; then
                rclone config
            fi

            echo
            info "Available rclone remotes:"
            rclone listremotes 2>/dev/null || { warn "No remotes configured."; return 1; }
            echo
            echo -ne "  ${CYAN}${ARROW}${NC} Remote destination ${DIM}(e.g. myremote:bucket/backups)${NC}: "
            read -r remote_dest
            [[ -z "$remote_dest" ]] && warn "No destination entered." && return

            # Test connection
            info "Testing connection..."
            if rclone lsd "$remote_dest" &>/dev/null || rclone mkdir "$remote_dest" &>/dev/null; then
                log "rclone remote verified: ${remote_dest}"
            else
                warn "Could not reach ${remote_dest}. Check your rclone config."
                if ! confirm "Save anyway?"; then
                    return
                fi
            fi

            cat > "$BACKUP_REMOTE_CONF" <<EOF
REMOTE_TYPE=rclone
REMOTE_DEST=${remote_dest}
EOF
            chmod 600 "$BACKUP_REMOTE_CONF"
            log "Remote sync configured: rclone -> ${remote_dest}"
            ;;
        2)
            # rsync over SSH
            echo -ne "  ${CYAN}${ARROW}${NC} Remote host ${DIM}(e.g. user@host.com)${NC}: "
            read -r rsync_host
            [[ -z "$rsync_host" ]] && warn "No host entered." && return

            echo -ne "  ${CYAN}${ARROW}${NC} Remote path ${DIM}(e.g. /home/user/backups)${NC}: "
            read -r rsync_path
            [[ -z "$rsync_path" ]] && warn "No path entered." && return

            local rsync_dest="${rsync_host}:${rsync_path}"

            # Test connection
            info "Testing SSH connection..."
            if ssh -o ConnectTimeout=10 -o BatchMode=yes "${rsync_host}" "mkdir -p ${rsync_path}" 2>/dev/null; then
                log "rsync remote verified: ${rsync_dest}"
            else
                warn "SSH connection failed. Ensure SSH key auth is set up for ${rsync_host}."
                if ! confirm "Save anyway?"; then
                    return
                fi
            fi

            cat > "$BACKUP_REMOTE_CONF" <<EOF
REMOTE_TYPE=rsync
REMOTE_DEST=${rsync_dest}
EOF
            chmod 600 "$BACKUP_REMOTE_CONF"
            log "Remote sync configured: rsync -> ${rsync_dest}"
            ;;
        3)
            if [[ -f "$BACKUP_REMOTE_CONF" ]]; then
                rm -f "$BACKUP_REMOTE_CONF"
                log "Remote sync disabled"
            else
                info "No remote sync was configured."
            fi
            return
            ;;
        *)
            warn "Invalid option."
            return
            ;;
    esac

    echo
    echo -e "  ${GREEN}${BOLD}Remote Sync Configured${NC}"
    separator
    source "$BACKUP_REMOTE_CONF"
    echo -e "    ${BOLD}Method${NC}      | ${REMOTE_TYPE}"
    echo -e "    ${BOLD}Destination${NC} | ${REMOTE_DEST}"
    separator
}

sync_backup_remote() {
    local backup_file="$1"
    [[ -f "$BACKUP_REMOTE_CONF" ]] || return 0

    source "$BACKUP_REMOTE_CONF"
    [[ -z "$REMOTE_TYPE" || -z "$REMOTE_DEST" ]] && return 0

    info "Syncing to remote (${REMOTE_TYPE})..."
    case "$REMOTE_TYPE" in
        rclone)
            if command -v rclone &>/dev/null; then
                rclone copy "$backup_file" "$REMOTE_DEST" 2>&1 | tee -a "$LOG_FILE" &
                spinner $! "Uploading to remote..."
                log "Synced to remote: $(basename "$backup_file")"
            else
                warn "rclone not found. Skipping remote sync."
            fi
            ;;
        rsync)
            if command -v rsync &>/dev/null; then
                rsync -az "$backup_file" "$REMOTE_DEST" 2>&1 | tee -a "$LOG_FILE" &
                spinner $! "Uploading to remote..."
                log "Synced to remote: $(basename "$backup_file")"
            else
                warn "rsync not found. Skipping remote sync."
            fi
            ;;
    esac
}

manage_backups() {
    header "Backup Manager"

    echo -e "    ${BOLD}${GREEN}1${NC} | Backup a site         ${DIM}-- full backup (files + database)${NC}"
    echo -e "    ${BOLD}${GREEN}2${NC} | Backup all sites      ${DIM}-- backup every site at once${NC}"
    echo -e "    ${BOLD}${CYAN}3${NC} | Restore a site        ${DIM}-- restore from a previous backup${NC}"
    echo -e "    ${BOLD}${BLUE}4${NC} | List backups          ${DIM}-- show all available backups${NC}"
    echo -e "    ${BOLD}${YELLOW}5${NC} | Setup auto-backup     ${DIM}-- daily/weekly scheduled backups${NC}"
    echo -e "    ${BOLD}${MAGENTA}6${NC} | Setup remote sync     ${DIM}-- S3, rsync, rclone${NC}"
    echo -e "    ${DIM}7${NC} | Back"
    echo
    echo -ne "  ${CYAN}${ARROW}${NC} Choose ${DIM}[1-7]${NC}: "
    read -r backup_choice

    case "$backup_choice" in
        1)
            pick_site "Site to backup" || { manage_backups; return; }
            backup_site "$PICKED_DOMAIN"
            ;;
        2) backup_all_sites ;;
        3)
            pick_site "Site to restore" || { manage_backups; return; }
            restore_site "$PICKED_DOMAIN"
            ;;
        4) list_backups ;;
        5) setup_backup_schedule ;;
        6) setup_remote_sync ;;
        7) return ;;
        *) warn "Invalid option."; manage_backups ;;
    esac
}

# ── List Sites ───────────────────────────────────────────────
list_sites() {
    header "Existing Sites"
    if [[ ! -d "$SITES_ROOT" ]] || [[ -z "$(ls -A "$SITES_ROOT" 2>/dev/null)" ]]; then
        warn "No sites found in ${SITES_ROOT}"
        return 1
    fi

    local i=1
    echo -e "    ${DIM}#   Domain                    Status    SSL       Mode${NC}"
    separator

    for dir in "${SITES_ROOT}"/*/; do
        [[ -d "$dir" ]] || continue
        local domain
        domain=$(basename "$dir")

        local status="${RED}inactive${NC}"
        [[ -L "${NGINX_ENABLED}/${domain}" ]] && status="${GREEN}active  ${NC}"

        local ssl="${YELLOW}none${NC}"
        if [[ -f "/etc/letsencrypt/live/${domain}/fullchain.pem" ]]; then
            local expiry
            expiry=$(openssl x509 -enddate -noout -in "/etc/letsencrypt/live/${domain}/fullchain.pem" 2>/dev/null \
                | sed 's/notAfter=//')
            if [[ -n "$expiry" ]]; then
                local expiry_epoch
                expiry_epoch=$(date -d "$expiry" +%s 2>/dev/null)
                local now_epoch
                now_epoch=$(date +%s)
                local days_left=$(( (expiry_epoch - now_epoch) / 86400 ))
                if (( days_left < 7 )); then
                    ssl="${RED}${days_left}d left${NC}"
                elif (( days_left < 30 )); then
                    ssl="${YELLOW}${days_left}d left${NC}"
                else
                    ssl="${GREEN}valid (${days_left}d)${NC}"
                fi
            else
                ssl="${GREEN}valid${NC}"
            fi
        fi

        local mode="public"
        if grep -q "127\.0\.0\.1.*${domain}" /etc/hosts 2>/dev/null; then
            mode="${CYAN}local${NC}"
        fi

        printf "    ${BOLD}%-3s${NC} | %-25s [%b]  [%b]  %b\n" "$i" "$domain" "$status" "$ssl" "$mode"
        (( i++ ))
    done
    separator
    echo
    return 0
}

# ── Pick Site ────────────────────────────────────────────────
pick_site() {
    local prompt="${1:-Select a site}"
    list_sites || return 1

    echo -ne "  ${CYAN}${ARROW}${NC} ${prompt} ${DIM}(number or domain)${NC}: "
    read -r PICK_INPUT
    [[ -z "$PICK_INPUT" ]] && return 1

    if [[ "$PICK_INPUT" =~ ^[0-9]+$ ]]; then
        local i=1
        for dir in "${SITES_ROOT}"/*/; do
            [[ -d "$dir" ]] || continue
            if [[ "$i" -eq "$PICK_INPUT" ]]; then
                PICKED_DOMAIN=$(basename "$dir")
                log "Selected: ${PICKED_DOMAIN}"
                return 0
            fi
            (( i++ ))
        done
        warn "No site with number ${PICK_INPUT}."
        return 1
    fi

    PICKED_DOMAIN="${PICK_INPUT,,}"
    [[ ! -d "${SITES_ROOT}/${PICKED_DOMAIN}" ]] && warn "Site ${PICKED_DOMAIN} not found." && return 1
    return 0
}

# ── Renew SSL ────────────────────────────────────────────────
renew_ssl() {
    header "Renewing SSL Certificates"
    info "Running certbot renew..."
    if certbot renew 2>&1 | tee -a "$LOG_FILE"; then
        log "Renewal check complete"
    else
        warn "Renewal had issues. Check the output above."
    fi

    # Reload nginx to pick up any new certs
    systemctl reload nginx 2>/dev/null || true
}

# ── Entry Point ──────────────────────────────────────────────
check_root
check_os
acquire_lock
setup_nginx_dirs
touch "$LOG_FILE"
log "Session started — ${DISTRO_FAMILY} | PHP ${PHP_VERSION} | user ${REAL_USER}"
main_menu
