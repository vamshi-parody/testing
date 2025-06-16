#!/bin/bash
set -e

# Configuration
ONLINE_SERVER="user@online-server-ip"
TARGET_SERVER="user@target-server-ip"
REPO_DIR="/home/testing/repo"
PKG_DIR="/home/testing/packages"
SSH_OPTS="-o StrictHostKeyChecking=no"
PKG_LIST_FILE="packages.txt"

# Create directories on online server
ssh $SSH_OPTS $ONLINE_SERVER "mkdir -p $PKG_DIR $REPO_DIR"

# Read package list from file
PACKAGES=()
while IFS= read -r pkg; do
    [[ -n "$pkg" ]] && PACKAGES+=("$pkg")
done < "$PKG_LIST_FILE"

# Download packages with dependencies
for pkg in "${PACKAGES[@]}"; do
    ssh $SSH_OPTS $ONLINE_SERVER "sudo dnf list installed $pkg >/dev/null 2>&1 || dnf download --resolve --alldeps -y $pkg -D downloaddir=$PKG_DIR"
done

# Copy GPG keys and create repo
ssh $SSH_OPTS $ONLINE_SERVER << 'EOF'
sudo cp /etc/pki/rpm-gpg/RPM-GPG-KEY-redhat-release $PKG_DIR
sudo cp /etc/pki/rpm-gpg/RPM-GPG-KEY-EPEL-9 $PKG_DIR
sudo mv $PKG_DIR/* $REPO_DIR
sudo createrepo $REPO_DIR
EOF

# Create repo file
REPO_CONTENT="[local]
name=Local Repository
baseurl=file://$REPO_DIR
enabled=1
gpgcheck=1
gpgkey=file://$REPO_DIR/RPM-GPG-KEY-redhat-release
       file://$REPO_DIR/RPM-GPG-KEY-EPEL-9"

ssh $SSH_OPTS $ONLINE_SERVER "echo '$REPO_CONTENT' | sudo tee $REPO_DIR/local.repo"

# Transfer from online server to jump server (if not already done)
scp $SSH_OPTS -r $ONLINE_SERVER:$REPO_DIR /tmp/local-repo

# Transfer from jump server to target server
scp $SSH_OPTS -r /tmp/local-repo $TARGET_SERVER:/home/testing/

# Install packages on target server (via SSH)
# Dynamically build install command from package list
INSTALL_CMD="sudo dnf install"
for pkg in "${PACKAGES[@]}"; do
    INSTALL_CMD+=" $pkg"
done
INSTALL_CMD+=" --refresh"

ssh $SSH_OPTS $TARGET_SERVER << EOF
sudo mkdir -p /opt/local-repo
sudo mv /home/testing/local-repo/* /opt/local-repo/
sudo cp /opt/local-repo/local.repo /etc/yum.repos.d/
sudo rpm --import /opt/local-repo/RPM-GPG-KEY-redhat-release
sudo rpm --import /opt/local-repo/RPM-GPG-KEY-EPEL-9
sudo dnf clean all
sudo dnf makecache
$INSTALL_CMD
EOF
