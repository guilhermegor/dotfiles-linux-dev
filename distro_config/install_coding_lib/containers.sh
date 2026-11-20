#!/bin/bash
#
# distro_config/install_coding_lib/containers.sh
#
# Container runtimes. Sourced by install_coding.sh.

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    echo "containers.sh is meant to be sourced, not executed." >&2
    exit 1
fi

install_docker() {
    print_status "section" "DOCKER INSTALLATION"

    if command_exists docker; then
        print_status "info" "Docker already installed"
        # Installed from the vendor apt repo → its key can rotate under us (#353).
        if [ -f /etc/apt/sources.list.d/docker.list ]; then
            refresh_apt_keyring https://download.docker.com/linux/ubuntu/gpg \
                /etc/apt/keyrings/docker.asc || return 1
        fi
        return 0
    fi

    print_status "info" "Adding Docker's GPG key..."
    sudo apt-get update
    run_or_echo sudo apt-get install -y ca-certificates curl
    run_or_echo sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    run_or_echo sudo chmod a+r /etc/apt/keyrings/docker.asc

    print_status "info" "Adding Docker repository..."
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" | \
      run_or_echo sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    sudo apt-get update

    print_status "info" "Installing Docker Engine..."
    run_or_echo sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    print_status "info" "Testing Docker installation..."
    # $LOG_FILE lives under $HOME (user-owned), so the user shell opens the
    # redirect correctly even though the command runs under sudo.
    # shellcheck disable=SC2024
    if sudo docker run hello-world &>> "$LOG_FILE"; then
        print_status "success" "Docker installed and working"
    else
        print_status "warning" "Docker installed but test failed"
    fi

    print_status "info" "Disabling Docker autostart..."
    run_or_echo sudo systemctl disable docker.service
    run_or_echo sudo systemctl disable docker.socket

    print_status "success" "Docker configured"
}

install_docker_desktop() {
    print_status "section" "DOCKER DESKTOP"

    if command_exists docker-desktop; then
        print_status "info" "Docker Desktop already installed"
        return 0
    fi

    cd "$DOWNLOADS_DIR" || return 1
    print_status "info" "Downloading Docker Desktop..."
    run_or_echo wget -O docker-desktop-amd64.deb "https://desktop.docker.com/linux/main/amd64/docker-desktop-amd64.deb?utm_source=docker&utm_medium=webreferral&utm_campaign=docs-driven-download-linux-amd64"

    print_status "info" "Installing Docker Desktop..."
    run_or_echo sudo apt-get install -y ./docker-desktop-amd64.deb

    print_status "success" "Docker Desktop installed"
    cd - > /dev/null || return 1
}

# kubectl may lag or lead the cluster by one minor version; override per cluster.
KUBECTL_MINOR="${KUBECTL_MINOR:-v1.37}"

install_kubectl() {
    print_status "section" "KUBECTL INSTALLATION"

    local keyring=/etc/apt/keyrings/kubernetes-apt-keyring.gpg
    local key_url="https://pkgs.k8s.io/core:/stable:/${KUBECTL_MINOR}/deb/Release.key"

    if command_exists kubectl; then
        print_status "info" "kubectl already installed"
        # Installed from the vendor apt repo → its key can rotate under us (#353).
        if [ -f /etc/apt/sources.list.d/kubernetes.list ]; then
            refresh_apt_keyring "$key_url" "$keyring" --dearmor || return 1
        fi
        return 0
    fi

    print_status "info" "Adding the Kubernetes GPG key..."
    sudo apt-get update
    run_or_echo sudo apt-get install -y ca-certificates curl gnupg
    refresh_apt_keyring "$key_url" "$keyring" --dearmor || return 1

    print_status "info" "Adding Kubernetes repository (${KUBECTL_MINOR})..."
    echo "deb [signed-by=${keyring}] https://pkgs.k8s.io/core:/stable:/${KUBECTL_MINOR}/deb/ /" | \
        run_or_echo sudo tee /etc/apt/sources.list.d/kubernetes.list > /dev/null

    sudo apt-get update

    print_status "info" "Installing kubectl..."
    run_or_echo sudo apt-get install -y kubectl

    if kubectl version --client &>> "$LOG_FILE"; then
        print_status "success" "kubectl installed and working"
    else
        print_status "warning" "kubectl installed but 'kubectl version --client' failed"
    fi
}

INSTALL_REGISTRY+=(
    "install_docker:Docker Engine::"
    "install_docker_desktop:Docker Desktop:Infra:docker-desktop.desktop"
    "install_kubectl:kubectl::"
)
