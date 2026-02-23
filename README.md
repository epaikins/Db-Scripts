# Fast MySQL Backup & Restore (50GB+)

Workflow to **backup** a large MySQL database and **restore** it on another server, targeting **under 1 hour** total for 50GB+ databases.

## Quick start

1. **Copy config and edit**
   ```bash
   cp config.example.env config.env
   # Set SOURCE_* (backup from) and TARGET_* (restore to), BACKUP_DIR, etc.
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
   ./workflow.sh restore-only ./backups/db_20250223_120000   # local path
   ./workflow.sh restore-only s3://my-bucket/mysql-backups/db_20250223_120000   # fetch from S3 then restore
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
S3_BUCKET=my-backup-bucket
S3_PREFIX=mysql-backups
AWS_REGION=us-east-1
```

- **Backup**: After each backup, the script runs `aws s3 sync` to upload the backup directory to `s3://<S3_BUCKET>/<S3_PREFIX>/<db>_<timestamp>/`. Requires **AWS CLI** and credentials (env vars, `~/.aws/credentials`, or IAM role).
- **Restore**: Use a full S3 URI as the backup path. The workflow downloads from S3 to a temporary directory, then restores:
  ```bash
  ./workflow.sh restore-only s3://my-bucket/mysql-backups/mydb_20250223_120000
  ```

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

## File layout

```
db-scripts/
├── config.example.env   # copy to config.env
├── config.env           # your settings (git-ignore this)
├── backup.sh            # backup (mydumper or mysqldump)
├── restore.sh           # restore (myloader or mysql)
├── workflow.sh          # full | backup-only | restore-only
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
   - **MODE**: `full`, `backup-only`, or `restore-only` (for `restore-only` set **BACKUP_PATH** to a local path or `s3://bucket/prefix/key`)
   - **S3_BUCKET** (optional): after backup, push to this bucket; set **AWS_CREDENTIAL_ID** for S3 access
   - For restore from S3, set **BACKUP_PATH** to the S3 URI and **AWS_CREDENTIAL_ID**

The pipeline runs with a 90-minute timeout, writes a temporary `config.env` from parameters and credentials, then runs `workflow.sh`. The job must run on an agent that has `mydumper`/`myloader` (or `mysqldump`/`mysql`), and for S3 also **aws** CLI and AWS credentials.

## Security

- Do **not** commit `config.env` (passwords). Add `config.env` to `.gitignore`.
- Prefer MySQL users with minimal required privileges; use SSL for connections if possible.
- **Passwords with special characters** (e.g. parentheses, `$`, quotes) are supported: config is loaded safely. Use `SOURCE_PASSWORD=my(pass)word` or wrap in single quotes: `SOURCE_PASSWORD='my(pass)word'`.
