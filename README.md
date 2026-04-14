# TrueNAS SCALE - Bareos Tape Archival

Native tape archival integration for TrueNAS SCALE using [Bareos](https://www.bareos.com/) (100% open-source, AGPLv3) as the backup engine.

Adds a **Tape Backup** section under Data Protection in the TrueNAS web interface with full GUI management of tape backup jobs, drive control, tape inventory, and restore operations.

## Features

- **Tape drive auto-detection** — scans SCSI devices for tape drives and changers
- **Backup job management** — create, schedule, and run backup jobs to tape with GFS rotation
- **Tape inventory** — label tapes, manage pools (Daily/Weekly/Monthly/Scratch), track volumes
- **Restore wizard** — multi-step guided restore from tape backups
- **Drive control** — status, rewind, eject operations from the GUI
- **Autochanger support** — optional tape library/autoloader integration via mtx
- **Pre-configured defaults** — sensible GFS tape rotation schedule out of the box

## Architecture

```
TrueNAS WebUI (Angular)  ←→  Middleware Plugin (Python)  ←→  Bareos Daemons
     Data Protection              tape_backup.*                 Director
     > Tape Backup                python-bareos                 Storage Daemon → /dev/nst0
                                  CRUDService                   File Daemon
                                                                PostgreSQL
```

**Three layers:**
1. Angular UI components under Data Protection (forms, tables, cards, stepper wizard)
2. Python middleware plugin using `python-bareos` to control Bareos via `DirectorConsoleJson`
3. Bareos daemons installed directly on TrueNAS host, managed via systemd

## Requirements

- TrueNAS SCALE 24.10+ (Electric Eel)
- LTO tape drive (SAS/FC HBA recommended)
- PostgreSQL (included with TrueNAS SCALE)

## Installation

**One-line install** (downloads everything from GitHub automatically):

```bash
curl -fsSL https://raw.githubusercontent.com/Jemplayer82/truenas-bareos-tape/main/install/install.sh | sudo bash
```

Or clone manually:

```bash
git clone https://github.com/Jemplayer82/truenas-bareos-tape.git
sudo ./truenas-bareos-tape/install/install.sh
```

The installer will:
1. Add the Bareos apt repository and install packages
2. Install tape utilities (mt-st, mtx, sg3-utils, lsscsi)
3. Install python-bareos
4. Initialize PostgreSQL database for Bareos catalog
5. Deploy the middleware plugin to `/usr/lib/python3/dist-packages/middlewared/plugins/tape_backup/`
6. Restart middlewared

### Post-install: Initial Setup

```bash
# Run first-time Bareos setup (generates config, starts services)
midclt call tape_backup.bareos.setup

# Verify tape drives are detected
midclt call tape_backup.drive.query

# Check service status
midclt call tape_backup.bareos.status
```

### WebUI Integration

The Angular components in `webui/` must be integrated into the TrueNAS webui build:

1. Copy `webui/src/app/pages/data-protection/tape-backup/` into your TrueNAS webui checkout
2. Add tape backup routes to `data-protection.routes.ts`
3. Add navigation entry in `navigation.service.ts`
4. Build the webui with `yarn build`

## Middleware API

All endpoints accessible via `midclt call` or WebSocket JSON-RPC:

| Endpoint | Description |
|----------|-------------|
| `tape_backup.job.query` | List backup job definitions |
| `tape_backup.job.create` | Create a backup job |
| `tape_backup.job.update` | Update a backup job |
| `tape_backup.job.delete` | Delete a backup job |
| `tape_backup.job.run` | Execute backup job immediately |
| `tape_backup.job.restore` | Restore files from tape |
| `tape_backup.drive.query` | Detect connected tape drives |
| `tape_backup.drive.status` | Get tape drive status |
| `tape_backup.drive.eject` | Eject tape from drive |
| `tape_backup.drive.rewind` | Rewind tape |
| `tape_backup.drive.configure` | Save drive configuration |
| `tape_backup.inventory.volumes` | List tape volumes |
| `tape_backup.inventory.pools` | List storage pools |
| `tape_backup.inventory.label` | Label a new tape |
| `tape_backup.inventory.purge` | Purge volume data |
| `tape_backup.inventory.recent_jobs` | Recent job history |
| `tape_backup.bareos.status` | Bareos daemon status |
| `tape_backup.bareos.start` | Start Bareos services |
| `tape_backup.bareos.stop` | Stop Bareos services |
| `tape_backup.bareos.setup` | First-time Bareos setup |

## Default Tape Rotation (GFS)

Pre-configured Grandfather-Father-Son rotation:

| Pool | Schedule | Retention |
|------|----------|-----------|
| Daily | Mon-Fri 21:00 (Incremental) | 7 days |
| Weekly | 2nd-5th Saturday 01:00 (Full) | 5 weeks |
| Monthly | 1st Saturday 01:00 (Full) | 12 months |
| Scratch | Recycle pool | Immediate reuse |

## Project Structure

```
middleware/plugins/tape_backup/
  bareos_mgr.py          — Bareos lifecycle, config generation
  drives.py              — Tape drive detection and control
  service.py             — Backup job CRUD + run/restore
  inventory.py           — Volume and pool management
  migration.py           — Database schema
  config_templates/*.j2  — 17 Bareos config templates

webui/src/app/pages/data-protection/tape-backup/
  tape-backup.routes.ts          — Angular routing
  tape-backup-dashboard/         — Overview dashboard
  tape-job-list/                 — Job list with actions
  tape-job-form/                 — Create/edit job form
  tape-drive-list/               — Drive management
  tape-inventory/                — Volume/pool management
  tape-restore/                  — Multi-step restore wizard
  tape-backup-card/              — Data Protection summary card

install/
  install.sh                     — Automated installer
  uninstall.sh                   — Clean uninstaller
```

## Uninstall

```bash
sudo ~/truenas-bareos-tape/install/uninstall.sh
```

Removes the middleware plugin and stops Bareos services. Bareos packages, configuration, and catalog database are preserved for manual cleanup.

## License

AGPLv3 — same as Bareos.
