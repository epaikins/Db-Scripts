# Fast MySQL Backup & Restore (50GB+)

Workflow to **backup** a large MySQL database and **restore** it on another server, targeting **under 1 hour** total for 50GB+ databases.

## Quick start

1. **Copy config and edit**
   ```bash
   cp config.example.env config.env
   # Set SOURCE_* (backup from), TARGET_* (restore to), BACKUP_DIR, RESTORE_PATH (for restore), etc.
   ```

2. **Install mydumper/myloader** (recommended for speed)
   - macOS: `brew install mydumper`
   - Ubuntu/Debian: `apt install mydumper`
   - Or build from: https://github.com/mydumper/mydumper

3. **Run full workflow** (backup on source host, then restore on target)
   ```bash
   chmod +x backup.sh restore.sh workflow.sh
   ./workflow.sh full
   ```

4. **Or run steps separately**
   ```bash
   ./workflow.sh backup-only                    # creates ./backups/<db>_<timestamp>; if S3_BUCKET set, pushes to S3
   # Restore: set RESTORE_PATH in your config (local dir or s3://...), then:
   make restore CONFIG=config.env
   # or: ./workflow.sh restore-only config.env
   ```

## Why this can finish in under 1 hour

| Approach | 50GB backup | 50GB restore | Notes |
|----------|-------------|--------------|--------|
| **mydumper + myloader** | ~15–25 min | ~20–35 min | Parallel threads, compression; **use this by default** |
| mysqldump + mysql | 30–60+ min | 45–90+ min | Single-threaded; fallback only |
| **Percona XtraBackup** | ~10–20 min | ~10–15 min | Physical backup; same MySQL version only |

- **mydumper**: multiple threads dump different tables/chunks in parallel.
- **myloader**: multiple threads load tables in parallel.
- **Compression** (default on) reduces disk I/O and transfer time.
- **Tuning** (see below) on source and target further reduces time.

## Prerequisites

- **MySQL 5.7+** (or MariaDB; mydumper supports both).
- **mydumper + myloader** for fast logical backup/restore (strongly recommended).
- Source user needs: `SELECT`, `LOCK TABLES`, `SHOW VIEW`, `TRIGGER`, `REPLICATION CLIENT`.
- Target user needs: `CREATE`, `INSERT`, `ALTER`, `DROP`, `INDEX`, and same for routines/triggers if you dump them.

## Performance tuning

### 1. Parallelism (`config.env`)

```bash
PARALLEL_JOBS=16   # or 24–32 on powerful servers; more = faster, more load
CHUNK_SIZE_MB=64   # chunk size per table for mydumper
COMPRESS=1         # keep 1 for large DBs (saves disk and network)
```

### 2. MySQL source (backup) server

- **innodb_buffer_pool_size**: large (e.g. 50–70% of RAM) so backup reads are fast.
- **max_allowed_packet**: e.g. 64M–256M if you have large rows.

### 3. MySQL target (restore) server

Temporarily for the restore session (or in config file for restore only):

```ini
innodb_buffer_pool_size = 4G
innodb_log_file_size = 512M
innodb_flush_log_at_trx_commit = 2
innodb_doublewrite = 0
foreign_key_checks = 0
unique_checks = 0
```

The restore script already sets `foreign_key_checks=0` and `unique_checks=0` for the session when using the mysql client.

### 4. Network (backup on one host, restore on another)

- Use **rsync** or **scp** with compression: backup is already compressed; rsync can still help.
- If backup and restore are on the same machine, skip transfer.

### 5. Disk

- Prefer **SSD/NVMe** for `BACKUP_DIR` and for MySQL datadir on target.
- Avoid writing backup to the same disk as the live datadir.

## S3: push after backup, restore from S3

Set in `config.env`:

```bash
S3_BUCKET=upt-database-backup
S3_PREFIX=upt                       # folder under date; all DB backups go in bucket/YYYYMMDD/upt/
AWS_REGION=us-east-1
```

Backups are stored as **bucket/YYYYMMDD/folder/db_timestamp.tar.gz**. The folder under the date defaults to `upt` (set via `S3_PREFIX`), so all DB objects go under e.g. `s3://upt-database-backup/20260223/upt/`.

- **Backup**: The script creates a gzipped tarball (`<db>_<timestamp>.tar.gz`) and streams it to S3. Requires **AWS CLI** and credentials.
- **Restore**: Set `RESTORE_PATH` in your config to the full S3 URI (or local backup dir), then run restore with that config:
  ```bash
  # In config.env: RESTORE_PATH=s3://upt-database-backup/20260223/upt/mydb_20260223_000001.tar.gz
  make restore CONFIG=config.env
  ```

## Teams notifications

You can post backup and restore completion messages to a **Microsoft Teams** channel using an Incoming Webhook.

1. **Create a webhook** in Teams: open the channel → Connectors (or channel name → Manage channel) → Incoming Webhook → Add, name it (e.g. "DB backups"), copy the URL.
2. **Set the URL** in your config:
   ```bash
   TEAMS_WEBHOOK_URL=https://outlook.office.com/webhook/...
   ```
   Put it in `config.env` for single-DB backup/restore and for the **cron summary** (when using `cron-backup-all.sh`). For per-DB notifications when running cron, you can also set it in each `configs/<name>.env`.
3. **What gets sent**:
   - **Backup done**: after each successful backup (database name, path, S3 URI if used); and on backup failure.
   - **Restore done**: after each successful restore (target DB, host, source path); and on restore failure.
   - **Cron run summary**: when `cron-backup-all.sh` finishes—either “All N backup(s) completed successfully” or “N failed” with the list of failed configs.

If `TEAMS_WEBHOOK_URL` is unset or not `https://`, notifications are skipped. Requires `curl` or `wget` and `python3` for JSON encoding.

## Optional: transfer backup to target host

In `config.env` set:

```bash
REMOTE_BACKUP_PATH=user@target-server:/path/to/backups/db_20250223_120000
```

Then run the restore on the target host with that path (e.g. `/path/to/backups/db_20250223_120000`). The full workflow script can use `rsync` to copy the backup to `REMOTE_BACKUP_PATH` before restore.

## Physical backup (Percona XtraBackup)

For **same MySQL version** and InnoDB-only (or compatible) setups, physical backup is usually the fastest:

```bash
./backup-xtrabackup.sh   # on source
# copy OUT_DIR to target, then on target:
./restore-xtrabackup.sh /path/to/xtra_backup
```

Restore requires stopping MySQL, then `xtrabackup --copy-back` (or rsync) and fixing ownership. See script comments.

## Midnight cron: multiple DBs on different servers → S3

To run a backup every night for **multiple databases on different servers** and push to **S3**:

1. **Create one config per server/DB** in `configs/`:
   ```bash
   cp configs/example-server.env.example configs/prod-app1.env
   cp configs/example-server.env.example configs/prod-app2.env
   # Edit each: SOURCE_HOST, SOURCE_*, S3_BUCKET (e.g. upt-database-backup), etc.
   ```
   Each config must have `SOURCE_*` and `S3_BUCKET` set. Backups go to `s3://<bucket>/YYYYMMDD/upt/<db>_<timestamp>.tar.gz`.

2. **Install AWS CLI** and ensure credentials are available (env vars, `~/.aws/credentials`, or IAM role).

3. **Run all backups** (manual or from cron):
   ```bash
   ./cron-backup-all.sh
   # or: make backup-all
   ```
   This runs `backup.sh` once per `configs/*.env`; each backup is uploaded to `s3://<bucket>/YYYYMMDD/upt/<db>_<timestamp>.tar.gz`.

4. **Schedule at midnight** (e.g. on the machine that can reach all MySQL servers and S3):

   **Option A – systemd service (recommended)**  
   Install a systemd timer that runs the backup daily at midnight:
   ```bash
   ./install-cron-backup-service.sh              # system-wide (uses sudo)
   # or for your user only (no sudo):
   ./install-cron-backup-service.sh --user
   ```
   Logs go to `/var/log/mysql-cron-backup.log` (system) or `./logs/cron-backup.log` (user). Use `--dry-run` to print the units without installing; `--skip-enable` to install but not enable/start the timer.

   **Option B – cron**  
   ```bash
   crontab -e
   ```
   Add:
   ```cron
   0 0 * * * /path/to/db-scripts/cron-backup-all.sh >> /var/log/mysql-cron-backup.log 2>&1
   ```
   Or with `make`:
   ```cron
   0 0 * * * cd /path/to/db-scripts && make cron-backup >> /var/log/mysql-cron-backup.log 2>&1
   ```

If any config fails, the script reports which one(s) and exits non-zero so cron can alert.

## File layout

```
db-scripts/
├── config.example.env   # copy to config.env
├── config.env           # your settings (git-ignore this)
├── configs/             # multi-DB cron: one .env per server/DB
│   └── example-server.env.example
├── backup.sh            # backup (mydumper or mysqldump); accepts CONFIG_FILE or config path
├── restore.sh           # restore (myloader or mysql)
├── workflow.sh          # full | backup-only | restore-only
├── cron-backup-all.sh   # run backup for every configs/*.env, push to S3
├── install-cron-backup-service.sh  # install systemd service + timer for daily backups
├── notify-teams.sh      # send backup/restore completion to Teams channel (optional)
├── backup-xtrabackup.sh # optional physical backup
├── restore-xtrabackup.sh
├── Jenkinsfile          # Jenkins pipeline
├── Makefile
├── README.md
└── backups/             # created by backup.sh
```

## Jenkins

A **Jenkinsfile** is provided for running backup/restore as a pipeline job.

1. **Create credentials** in Jenkins (Manage Jenkins → Credentials): two **Secret text** credentials containing the source and target MySQL passwords. Note their credential IDs.
2. **Create a Pipeline job** (New Item → Pipeline) and set “Pipeline script from SCM” to this repo; script path: `Jenkinsfile`.
3. **First run**: open “Build with Parameters” and set:
   - **SOURCE_CREDENTIAL_ID** / **TARGET_CREDENTIAL_ID** to the credential IDs from step 1
   - **SOURCE_HOST**, **SOURCE_USER**, **SOURCE_DATABASE** (and target equivalents) to your servers and DB names
   - **MODE**: `full`, `backup-only`, or `restore-only` (for `restore-only` the generated config must set **RESTORE_PATH** to a local path or `s3://bucket/prefix/key`)
   - **S3_BUCKET** (optional): after backup, push to this bucket; set **AWS_CREDENTIAL_ID** for S3 access
   - For restore from S3, set **RESTORE_PATH** to the S3 URI in the config and **AWS_CREDENTIAL_ID**

The pipeline runs with a 90-minute timeout, writes a temporary `config.env` from parameters and credentials, then runs `workflow.sh`. The job must run on an agent that has `mydumper`/`myloader` (or `mysqldump`/`mysql`), and for S3 also **aws** CLI and AWS credentials.

## Security

- Do **not** commit `config.env` (passwords). Add `config.env` to `.gitignore`.
- Prefer MySQL users with minimal required privileges; use SSL for connections if possible.
- **Passwords with special characters** (e.g. parentheses, `$`, quotes) are supported: config is loaded safely. Use `SOURCE_PASSWORD=my(pass)word` or wrap in single quotes: `SOURCE_PASSWORD='my(pass)word'`.
