# Stalwart upgrade script

Interactive upgrade / downgrade for a [Stalwart](https://github.com/stalwartlabs/stalwart) server installed with the official `install.sh` on Linux with systemd.

## What it does

1. Detects the CPU architecture and libc (`x86_64-unknown-linux-gnu`, `aarch64-…-musl`, …).
2. Reads the binary path from `ExecStart=` of the `stalwart` systemd unit and checks it against `which stalwart`.
3. Gets the installed version from `stalwart --version`.
4. Lists the GitHub releases that have a build for this architecture, with menu options for upgrade, downgrade, reinstall and showing release notes.
5. Before installing, shows the release notes of **every** version between the installed and the target version. Lines that look like upgrade hints are highlighted and listed again at the end.
6. Downloads the build. If `cosign` is installed, it checks the sigstore signature.
7. Stops the service, swaps the binary, starts the service again and shows its status and the last log lines.

The script does **not** keep a backup of the old binary. Use your system backups, or re-run the script and downgrade.

## Requirements

`bash` ≥ 4.3, `curl`, `jq`, `tar`, `systemd`, root. Optional: `cosign` (signature check), `less` (pager).

## Usage

```bash
sudo ./stalwart-upgrade.sh              # interactive menu
sudo ./stalwart-upgrade.sh --dry-run    # everything except stop/replace/start
```

| Option | Meaning |
| --- | --- |
| `--fdb` | Use the FoundationDB build (auto-detected via `ldd` otherwise) |
| `--service NAME` | systemd unit name (default `stalwart`) |
| `--include-prerelease` | Also offer pre-releases |
| `--no-verify` | Skip the cosign check |
| `--dry-run` | Don't touch the service or binary |

Set `GITHUB_TOKEN` if you hit the GitHub API rate limit.
