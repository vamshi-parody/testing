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

# Copy packages.txt to repo directory for reference
scp $SSH_OPTS "$PKG_LIST_FILE" $ONLINE_SERVER:$REPO_DIR/

# Compress repo on online server
ssh $SSH_OPTS $ONLINE_SERVER "tar -czvf $REPO_DIR.tar.gz -C $(dirname $REPO_DIR) $(basename $REPO_DIR)"

# Transfer compressed repo to jump server
scp $SSH_OPTS $ONLINE_SERVER:$REPO_DIR.tar.gz /tmp/

# Transfer compressed repo to target server
scp $SSH_OPTS /tmp/$(basename $REPO_DIR).tar.gz $TARGET_SERVER:/home/testing/

# Decompress and setup repo on target server
ssh $SSH_OPTS $TARGET_SERVER << 'EOF'
sudo mkdir -p /opt/local-repo
sudo tar -xzvf /home/testing/repo.tar.gz -C /opt/local-repo --strip-components=1
sudo cp /opt/local-repo/local.repo /etc/yum.repos.d/
sudo rpm --import /opt/local-repo/RPM-GPG-KEY-redhat-release
sudo rpm --import /opt/local-repo/RPM-GPG-KEY-EPEL-9
sudo dnf clean all
sudo dnf makecache
# sudo dnf install $(tr '\n' ' ' < /opt/local-repo/packages.txt) --refresh
EOF

# Print manual install command
echo
echo "# To install packages on the target server, run:"
echo "# sudo dnf install \$(tr '\n' ' ' < /opt/local-repo/packages.txt) --refresh"
