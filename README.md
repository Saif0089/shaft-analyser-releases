# Shaft Analyser — Delta Scan Engineering

Mine-shaft LiDAR analysis on your own computer: drift and twist audit (M1), correction check (M2) and structural
segmentation into guide rails, buntons, services and barrel wall (M3). Scans never leave your machine.

## Install (one command)

macOS (Apple Silicon) / Linux (64-bit), in Terminal:
```sh
curl -fsSL https://github.com/Saif0089/shaft-analyser-releases/releases/latest/download/install.sh | sh
```

Windows, in PowerShell:
```powershell
irm https://github.com/Saif0089/shaft-analyser-releases/releases/latest/download/install.ps1 | iex
```

Windows, in Command Prompt (cmd):
```bat
powershell -NoProfile -c "irm https://github.com/Saif0089/shaft-analyser-releases/releases/latest/download/install.ps1 | iex"
```

No administrator rights needed. It installs into `ShaftAnalyser` in your home folder, prepares Python and the libraries
inside it (internet once, a few minutes) and opens the app in your browser.

## Use
| Command | |
|---|---|
| `shaft-analyser` | start the app |
| `shaft-analyser check` | self-check: the whole pipeline on the bundled synthetic shaft, scored against its ground truth |
| `shaft-analyser doctor` | check this computer and the install |
| `shaft-analyser update` | look for a newer version now |
| `shaft-analyser uninstall` | remove the program (your shafts and results are kept) |

The app updates itself: every release here has passed installation, the self-check and an update test on clean
Windows, Linux and macOS machines. Updates are verified against `checksums.txt`, install only when no scan is being
processed, and roll back by themselves if a new version does not start.
