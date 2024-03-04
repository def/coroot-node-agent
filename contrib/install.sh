#!/bin/sh
set -e
set -o noglob

# Usage:
#   curl ... | ENV_VAR=... sh -
#       or
#   ENV_VAR=... ./install.sh

# Environment variables:

GITHUB_URL=https://github.com/coroot/coroot-node-agent/releases
STORAGE_URL=https://k3s-ci-builds.s3.amazonaws.com
DOWNLOADER=
SYSTEM_NAME=coroot-node-agent
SUDO=sudo
if [ $(id -u) -eq 0 ]; then
    SUDO=
fi

BIN_DIR=/usr/bin
SYSTEMD_DIR=/etc/systemd/system

SYSTEMD_SERVICE=${SYSTEM_NAME}.service
UNINSTALL_SH=${BIN_DIR}/${SYSTEM_NAME}-uninstall.sh
FILE_SERVICE=${SYSTEMD_DIR}/${SYSTEMD_SERVICE}
FILE_ENV=${SYSTEMD_DIR}/${SYSTEMD_SERVICE}.env

info()
{
    echo '[INFO] ' "$@"
}
fatal()
{
    echo '[ERROR] ' "$@" >&2
    exit 1
}

verify_system() {
    if [ -x /bin/systemctl ] || type systemctl > /dev/null 2>&1; then
        return
    fi
    fatal 'Cannot find systemd'
}

verify_executable() {
    if [ ! -x ${BIN_DIR}/coroot-node-agent ]; then
        fatal "Executable coroot-node-agent binary not found at ${BIN_DIR}/coroot-node-agent"
    fi
}

verify_arch() {
    if [ -z "$ARCH" ]; then
        ARCH=$(uname -m)
    fi
    case $ARCH in
        amd64)
            ARCH=amd64
            SUFFIX=
            ;;
        x86_64)
            ARCH=amd64
            SUFFIX=
            ;;
#        arm64)
#            ARCH=arm64
#            SUFFIX=-${ARCH}
#            ;;
#        aarch64)
#            ARCH=arm64
#            SUFFIX=-${ARCH}
#            ;;
        *)
            fatal "Unsupported architecture $ARCH"
    esac
}

verify_downloader() {
    [ -x "$(command -v $1)" ] || return 1
    DOWNLOADER=$1
    return 0
}

# --- create temporary directory and cleanup when done ---
setup_tmp() {
    TMP_DIR=$(mktemp -d -t k3s-install.XXXXXXXXXX)
    TMP_HASH=${TMP_DIR}/k3s.hash
    TMP_ZIP=${TMP_DIR}/k3s.zip
    TMP_BIN=${TMP_DIR}/k3s.bin
    cleanup() {
        code=$?
        set +e
        trap - EXIT
        rm -rf ${TMP_DIR}
        exit $code
    }
    trap cleanup INT EXIT
}

# --- use desired k3s version if defined or find version from channel ---
get_release_version() {
    info "Finding release for channel ${INSTALL_K3S_CHANNEL}"
    version_url="${INSTALL_K3S_CHANNEL_URL}/${INSTALL_K3S_CHANNEL}"
    case $DOWNLOADER in
        curl)
            VERSION_K3S=$(curl -w '%{url_effective}' -L -s -S ${version_url} -o /dev/null | sed -e 's|.*/||')
            ;;
        wget)
            VERSION_K3S=$(wget -SqO /dev/null ${version_url} 2>&1 | grep -i Location | sed -e 's|.*/||')
            ;;
        *)
            fatal "Incorrect downloader executable '$DOWNLOADER'"
            ;;
    info "Using ${VERSION_K3S} as release"
}

# --- download from github url ---
download() {
    [ $# -eq 2 ] || fatal 'download needs exactly 2 arguments'
    set +e
    case $DOWNLOADER in
        curl)
            curl -o $1 -sfL $2
            ;;
        wget)
            wget -qO $1 $2
            ;;
        *)
            fatal "Incorrect executable '$DOWNLOADER'"
            ;;
    esac

    # Abort if download command failed
    [ $? -eq 0 ] || fatal 'Download failed'
    set -e
}

# --- download hash from github url ---
download_hash() {
    HASH_URL=${GITHUB_URL}/download/${AGENT_VERSION}/sha256sum-${ARCH}.txt

    info "Downloading hash ${HASH_URL}"
    download ${TMP_HASH} ${HASH_URL}
    fi
    HASH_EXPECTED=$(grep " k3s${SUFFIX}$" ${TMP_HASH})
    HASH_EXPECTED=${HASH_EXPECTED%%[[:blank:]]*}
}

# --- check hash against installed version ---
installed_hash_matches() {
    if [ -x ${BIN_DIR}/k3s ]; then
        HASH_INSTALLED=$(sha256sum ${BIN_DIR}/k3s)
        HASH_INSTALLED=${HASH_INSTALLED%%[[:blank:]]*}
        if [ "${HASH_EXPECTED}" = "${HASH_INSTALLED}" ]; then
            return
        fi
    fi
    return 1
}

# --- download binary from github url ---
download_binary() {
    if [ -n "${INSTALL_K3S_PR}" ]; then
        # Since Binary and Hash are zipped together, check if TMP_ZIP already exists
        if ! [ -f ${TMP_ZIP} ]; then
            info "Downloading K3s artifact ${GITHUB_PR_URL}"
            curl -o ${TMP_ZIP} -H "Authorization: Bearer $GITHUB_TOKEN" -L ${GITHUB_PR_URL}
        fi
        # extract k3s binary from zip
        unzip -p ${TMP_ZIP} k3s > ${TMP_BIN}
        return
    elif [ -n "${INSTALL_K3S_COMMIT}" ]; then
        BIN_URL=${STORAGE_URL}/k3s${SUFFIX}-${INSTALL_K3S_COMMIT}
    else
        BIN_URL=${GITHUB_URL}/download/${VERSION_K3S}/k3s${SUFFIX}
    fi
    info "Downloading binary ${BIN_URL}"
    download ${TMP_BIN} ${BIN_URL}
}

# --- verify downloaded binary hash ---
verify_binary() {
    info "Verifying binary download"
    HASH_BIN=$(sha256sum ${TMP_BIN})
    HASH_BIN=${HASH_BIN%%[[:blank:]]*}
    if [ "${HASH_EXPECTED}" != "${HASH_BIN}" ]; then
        fatal "Download sha256 does not match ${HASH_EXPECTED}, got ${HASH_BIN}"
    fi
}

# --- setup permissions and move binary to system directory ---
setup_binary() {
    chmod 755 ${TMP_BIN}
    info "Installing k3s to ${BIN_DIR}/k3s"
    $SUDO chown root:root ${TMP_BIN}
    $SUDO mv -f ${TMP_BIN} ${BIN_DIR}/k3s
}

download_and_verify() {
    verify_arch
    verify_downloader curl || verify_downloader wget || fatal 'Can not find curl or wget for downloading files'
    setup_tmp
    get_release_version
    download_hash

    if installed_hash_matches; then
        info 'Skipping binary downloaded, installed k3s matches hash'
        return
    fi

    download_binary
    verify_binary
    setup_binary
}


create_uninstall() {
    [ "${INSTALL_K3S_BIN_DIR_READ_ONLY}" = true ] && return
    info "Creating uninstall script ${UNINSTALL_K3S_SH}"
    $SUDO tee ${UNINSTALL_K3S_SH} >/dev/null << EOF
#!/bin/sh
set -x
[ \$(id -u) -eq 0 ] || exec sudo \$0 \$@

systemctl stop ${SYSTEM_NAME}
systemctl disable ${SYSTEM_NAME}
systemctl reset-failed ${SYSTEM_NAME}
systemctl daemon-reload

rm -f ${FILE_SERVICE}
rm -f ${FILE_ENV}

remove_uninstall() {
    rm -f ${UNINSTALL_SH}
}
trap remove_uninstall EXIT

rm -rf /var/lib/coroot-node-agent || true
rm -f ${BIN_DIR}/coroot-node-agent
EOF
    $SUDO chmod 755 ${UNINSTALL_SH}
    $SUDO chown root:root ${UNINSTALL_SH}
}

systemd_disable() {
    $SUDO systemctl disable ${SYSTEM_NAME} >/dev/null 2>&1 || true
    $SUDO rm -f /etc/systemd/system/${SERVICE_K3S} || true
    $SUDO rm -f /etc/systemd/system/${SERVICE_K3S}.env || true
}

create_env_file() {
    info "env: Creating environment file ${FILE_ENV}"
    $SUDO touch ${FILE_ENV}
    $SUDO chmod 0600 ${FILE_ENV}
    sh -c export | while read x v; do echo $v; done | grep -E '^(K3S|CONTAINERD)_' | $SUDO tee ${FILE_ENV} >/dev/null
    sh -c export | while read x v; do echo $v; done | grep -Ei '^(NO|HTTP|HTTPS)_PROXY' | $SUDO tee -a ${FILE_ENV} >/dev/null
}

create_systemd_service_file() {
    info "systemd: Creating service file ${FILE_SERVICE}"
    $SUDO tee ${FILE_SERVICE} >/dev/null << EOF
[Unit]
Description=Coroot node agent
Documentation=https://coroot.com
Wants=network-online.target
After=network-online.target

[Install]
WantedBy=multi-user.target

[Service]
Type=exec
EnvironmentFile=-/etc/default/%N
EnvironmentFile=-/etc/sysconfig/%N
EnvironmentFile=-${FILE_ENV}
KillMode=process
Delegate=yes
# Having non-zero Limit*s causes performance problems due to accounting overhead
# in the kernel. We recommend using cgroups to do container-local accounting.
LimitNOFILE=1048576
LimitNPROC=infinity
LimitCORE=infinity
TasksMax=infinity
TimeoutStartSec=0
Restart=always
RestartSec=5s
ExecStart=${BIN_DIR}/coroot-node-agent
EOF
}

create_service_file() {
    create_systemd_service_file
    return 0
}

get_installed_hashes() {
    $SUDO sha256sum ${BIN_DIR}/coroot-node-agent ${FILE_SERVICE} ${FILE_ENV} 2>&1 || true
}

systemd_enable() {
    info "systemd: Enabling ${SYSTEM_NAME} unit"
    $SUDO systemctl enable ${FILE_SERVICE} >/dev/null
    $SUDO systemctl daemon-reload >/dev/null
}

systemd_start() {
    info "systemd: Starting ${SYSTEM_NAME}"
    $SUDO systemctl restart ${SYSTEM_NAME}
}


service_enable_and_start() {
    systemd_enable

    POST_INSTALL_HASHES=$(get_installed_hashes)
    if [ "${PRE_INSTALL_HASHES}" = "${POST_INSTALL_HASHES}" ]; then
        info 'No change detected so skipping service start'
        return
    fi

    systemd_start

    return 0
}

# --- run the install process --
{
    verify_system
    download_and_verify
    create_uninstall
    systemd_disable
    create_env_file
    create_service_file
    service_enable_and_start
}
