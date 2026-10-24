# Host Setup

Everything needed to go from a bare Proxmox VM to a running rootless Podman host, in install order.

- [Proxmox Setup](#proxmox-setup)
- [Debian Setup](#debian-setup)
- [Basic packages](#basic-packages)
- [Firewall](#firewall)
- [Static IP address](#static-ip-address)
- [Podman](#podman)
- [Git Deployment](#git-deployment)
- [Bitwarden CLI](#bitwarden-cli)

For running services, see [services.md](services.md); for day-2 tasks, see [operations.md](operations.md).

## Proxmox Setup

### VM settings

Dump of the virtual machine config by using `qm config 102`:

```
agent: 1
bios: ovmf
boot: order=scsi0;ide2;net0
cores: 4
cpu: host
efidisk0: local-lvm:vm-<ID>-disk-0,efitype=4m,ms-cert=2023,pre-enrolled-keys=1,size=4M
hostpci0: <PCI-ID>,pcie=1
ide2: none,media=cdrom
machine: q35
memory: 8192
meta: creation-qemu=10.1.2,ctime=<TIMESTAMP>
name: Homebase
net0: virtio=<MAC-ADDRESS>,bridge=vmbr0,firewall=1
numa: 0
ostype: l26
rng0: source=/dev/urandom
scsi0: local-lvm:vm-<ID>-disk-1,iothread=1,size=128G,ssd=1
scsihw: virtio-scsi-single
smbios1: uuid=<UUID>
sockets: 1
tpmstate0: local-lvm:vm-<ID>-disk-2,size=4M,version=v2.0
vmgenid: <VMGENID>
```

### iGPU passthrough

**Requirements**
- IOMMU needs to be supported and enabled in BIOS/UEFI
  e.g. look for VT-d in BIOS settings for Intel CPUs

1. **Check if IOMMU is enabled** by running `dmesg | grep -e DMAR -e IOMMU` and there should be an output like `DMAR: IOMMU enabled`. If this is not the case add `intel_iommu=on iommu=pt` to the kernel parameters by editing `GRUB_CMDLINE_LINUX_DEFAULT` in `/etc/default/grub` so it looks like this `GRUB_CMDLINE_LINUX_DEFAULT="quiet intel_iommu=on iommu=pt"`. Then run `update-grub` to apply changes and reboot.

2. **Check IOMMU interrupt remapping is enabled** by running `dmesg | grep 'remapping'`, you should see `DMAR-IR: Enabled IRQ remapping in x2apic mode`

3. **Verify IOMMU isolation** by executing `pvesh get /nodes/fafnir/hardware/pci --pci-class-blacklist ""`

4. **Find graphics card driver** by `lspci -nnk` and look for the loaded kernel module of the graphics card. Currently we have `Kernel driver in use: i915`

5. **Blacklist the driver** by executing `echo "blacklist i915" >> /etc/modprobe.d/blacklist.conf` and update the initramfs `update-initramfs -u -k all` and reboot

**noVNC**
Once the real graphics card has been forwarded, noVNC will not work due to the fact that the real graphics card is used. SSH and other remote desktop solutions will work without trouble.

**Resources**
- [Proxmox wiki: PCI Passthrough](https://pve.proxmox.com/wiki/PCI_Passthrough)
- [Proxmox wiki: PCI(e) Passthrough](<https://pve.proxmox.com/wiki/PCI(e)_Passthrough>)
- [Video walkthrough (YouTube)](https://www.youtube.com/watch?v=Pjjyuk4YU78)

## Debian Setup

### Install sudo

```bash
apt update
apt install sudo
usermod -aG sudo chef
```
logout and login to apply changes

### Qemu guest agent

```bash
apt update
apt install qemu-guest-agent
```
Enable the service

```bash
systemctl enable qemu-guest-agent
systemctl start qemu-guest
```

## Basic packages

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y \
  curl wget git tmux nvtop btop \
  ca-certificates gnupg lsb-release \
  jq unzip fastfetch
```

### Base CLI & Developer Utilities

- **curl**  
    Command-line tool for transferring data over URLs; commonly used for API calls, web requests, and scripted downloads.
- **wget**  
    Non-interactive file downloader optimized for reliable and recursive downloads over HTTP/HTTPS/FTP.
- **git**  
    Distributed version control system for tracking source code changes and collaborating on software projects.
- **tmux**  
    Terminal multiplexer enabling multiple persistent terminal sessions, panes, and tabs within a single terminal.
- **fastfetch**  
    Actively maintained, high-performance successor to Neofetch that displays system information with an ASCII distribution logo.

### System & Resource Monitoring

- **btop**  
    Modern, high-performance system monitor with a rich TUI for CPU, memory, disk, network, and process inspection.
- **nvtop**  
    Interactive GPU monitoring tool (top-like) for NVIDIA/AMD/Intel GPUs, showing utilization, memory, and processes.

### Security, Trust & OS Metadata

- **ca-certificates**  
    System-wide collection of trusted Certificate Authority certificates required for TLS/HTTPS verification.
- **gnupg**  
    Cryptographic toolset implementing OpenPGP, used for signing, verification, and secure key management.
- **lsb-release**  
    Provides Linux distribution identification (name, version, codename) for scripts and installers.

### Data Processing & Archive Handling

- **jq**  
    Lightweight and powerful command-line processor for filtering, transforming, and querying JSON data.
- **unzip**  
    Utility for extracting ZIP archives, commonly for downloaded tools and build artifacts.

### fastfetch MOTD

Create a motd file for fastfetch, usually there is a `10-uname` file already in `update-motd.d` which can be deleted

```bash
echo -e '#!/bin/sh\n/usr/bin/fastfetch' | sudo tee /etc/update-motd.d/50-fastfetch >/dev/null && sudo chmod +x /etc/update-motd.d/50-fastfetch
```

Verify

```bash
run-parts /etc/update-motd.d/
```

### Enable linger

Allows a user's systemd user services to run without an active login session.
This is required when background tasks (e.g., rootless Podman containers, timers, daemons) must start at boot and keep running after logout.
This is also a prerequisite for the [podman-compose systemd units](services.md#autostart-podman-compose-systemd-units-shared-pattern).

**Enable:**
```bash
sudo loginctl enable-linger USERNAME
```

**Verify:**
```bash
loginctl show-user USERNAME | grep Linger
```

## Firewall

**ufw**
Don't use `ufw` as your firewall, as it interferes directly with podman networking and is a pain to work with since it doesn't support zones.

**Summary**
- **`firewalld` is first-class supported by Podman** and integrates directly with Podman's networking stack (`netavark`).
- **`ufw` works, but is not Podman-aware** and frequently blocks container traffic unless you add forwarding and bridge rules manually.
- If you want **predictable behavior, less firewall debugging, and future-proofing**, prefer **firewalld**.

Install `firewalld` via apt

```bash
sudo apt update && sudo apt install firewalld -y
sudo systemctl enable --now firewalld
```

Verify

```bash
sudo firewall-cmd --version
```

Ensure that `ssh` remains accessible

```bash
sudo firewall-cmd --add-service=ssh --permanent
sudo firewall-cmd --reload
```

Service-specific rules (Caddy ports, DNS) are listed in [services.md](services.md).

## Static IP address

Static IP address is set by **Fritzbox**.

## Podman

```bash
sudo apt install -y podman podman-compose
```

Setup the container registries in `/etc/containers/registries.conf`, otherwise you cannot pull from any public registry without stating the full URL.

```bash
unqualified-search-registries = [
  "docker.io",
  "quay.io"
]

[[registry]]
prefix = "docker.io"
location = "docker.io"

[[registry]]
prefix = "quay.io"
location = "quay.io"
```

Enable the rootless podman socket

```bash
systemctl --user enable --now podman.socket
systemctl --user status podman.socket
```

Do the same with sudo to enable rootful podman socket

```bash
sudo systemctl --user enable --now podman.socket
sudo systemctl --user status podman.socket
```

Allow low unprivileged ports for e.g. `caddy`, `adguard-home`

```bash
echo "net.ipv4.ip_unprivileged_port_start = 53" | \
  sudo tee /etc/sysctl.d/90-unprivileged-ports.conf
```
Reboot and verify:

```bash
sysctl net.ipv4.ip_unprivileged_port_start
# expected: 80
```

For everyday commands see the [Podman cheatsheet](podman.md).

## Git Deployment

Create a ssh key for read-only deployment access:

```bash
ssh-keygen -t ed25519
```

Print out the public key

```bash
cat /home/chef/.ssh/id_ed25519.pub
```

And add it to the github projects in `homebase` -> `Settings` -> `Deploy keys`. Make sure it is a read-only key, commits always happen from the developer workstation.

See also [GitHub Docs: Deploy keys](https://docs.github.com/en/authentication/connecting-to-github-with-ssh/managing-deploy-keys#deploy-keys)

## Bitwarden CLI

There is no native `bitwarden-cli` package in the default debian repos. Hence we use [WakeMeOps](https://docs.wakemeops.com/) as a source.

1. Add WakeMeOps repository

```bash
curl -sSL https://raw.githubusercontent.com/upciti/wakemeops/main/assets/install_repository | sudo bash
```

2. Install bitwarden-cli

```bash
sudo apt install bitwarden-cli
```
