# Stalwart upgrade script

Interactive upgrade / downgrade for a [Stalwart](https://github.com/stalwartlabs/stalwart) server installed with the official `install.sh`.

Supports the same setups as `install.sh`:

| OS | Service manager | Service definition read |
| --- | --- | --- |
| Linux | systemd | `ExecStart=` of the `stalwart` unit (incl. drop-ins) |
| Linux | init.d | `DAEMON=` in `/etc/init.d/stalwart` |
| macOS | launchd | `ProgramArguments` in `/Library/LaunchDaemons/stalwart.plist` |
| FreeBSD | rc.d | `procname=` in `/usr/local/etc/rc.d/stalwart` |

Installs under a custom `PREFIX` (`install.sh /opt/stalwart`) work too. The binary path always comes from the service definition.

## What it does

1. Detects the OS, the CPU architecture and on Linux the libc (`x86_64-unknown-linux-gnu`, `aarch64-apple-darwin`, `x86_64-unknown-freebsd`, …).
2. Reads the binary path from the service definition and checks it against `which stalwart`.
3. Gets the installed version from `stalwart --version`. On Linux it also detects the FoundationDB build (`--fdb` forces it).
4. Lists the GitHub releases that have a build for this platform, with menu options for upgrade, downgrade, reinstall and showing release notes.
5. Before installing, shows the release notes of **every** version between the installed and the target version. Lines that look like upgrade hints are highlighted and listed again at the end.
6. Downloads the build. If `cosign` is installed, it checks the sigstore signature.
7. Stops the service, swaps the binary, starts the service again and shows its status and recent log lines (journal for systemd, plus the Stalwart log file in `/var/log/stalwart` or `<PREFIX>/logs`).

The script does **not** keep a backup of the old binary. Use your system backups, or re-run the script and downgrade.

## Requirements

- `bash` ≥ 4.3
  - macOS: `brew install bash`
  - FreeBSD: `pkg install bash`
- `curl`, `jq`, `tar`, root
- Optional: `cosign` (signature check), `less` (pager)

If something is missing, the script offers to install it with the system package manager (`apt-get`, `dnf`, `yum`, `zypper`, `pacman`, `apk`, `pkg`). On macOS it tells you the `brew install` command to run.

## Usage

```bash
sudo ./stalwart-upgrade.sh              # interactive menu
sudo ./stalwart-upgrade.sh --dry-run    # everything except stop/replace/start

# macOS (system bash is 3.2):
sudo "$(brew --prefix)/bin/bash" ./stalwart-upgrade.sh
```

| Option | Meaning |
| --- | --- |
| `--fdb` | Use the FoundationDB build (auto-detected via `ldd` on Linux) |
| `--service NAME` | Service name (default `stalwart`) |
| `--include-prerelease` | Also offer pre-releases |
| `--no-verify` | Skip the cosign check |
| `--dry-run` | Don't touch the service or binary |

Set `GITHUB_TOKEN` if you hit the GitHub API rate limit. Set `TMPDIR` to download somewhere other than `/var/tmp`.
