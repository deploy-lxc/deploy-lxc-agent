# Deploy LXC Agent - Incus

This directory contains the deployment script for setting up LXC containers with Incus.

## Quick Start

To download and run the deployment script, execute the following command:

```bash
curl -sSL https://github.com/deploy-lxc/deploy-lxc-agent/releases/download/latest/deploylxc.sh -o deploylxc.sh && chmod +x deploylxc.sh && bash deploylxc.sh
```

## What This Command Does

1. **Downloads the script**: Uses `curl` to fetch the latest version of `deploylxc.sh` from GitHub releases
2. **Makes it executable**: Sets execute permissions with `chmod +x`
3. **Runs the script**: Executes the deployment script with `bash`

## Requirements

- `curl` installed on your system
- Appropriate permissions to execute scripts
- Internet connection to download from GitHub

## Manual Installation

If you prefer to run the steps separately:

```bash
# Download the script
curl -sSL https://github.com/deploy-lxc/deploy-lxc-agent/releases/latest/download/deploylxc.sh -o deploylxc.sh

# Make it executable
chmod +x deploylxc.sh

# Run the script
bash deploylxc.sh
```
