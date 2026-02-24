# MySQL fast backup/restore (50GB+) - Makefile
SHELL := /bin/bash

.PHONY: help config backup restore full backup-xtra restore-xtra backup-all cron-backup clean check

help:
	@echo "MySQL backup/restore workflow (50GB+, sub-1hr target)"
	@echo ""
	@echo "  make config          - Copy config.example.env -> config.env (if missing)"
	@echo "  make backup          - Backup from source MySQL only"
	@echo "  make restore         - Restore (BACKUP_PATH=./backups/db_* or s3://bucket/prefix/db_*.tar.gz)"
	@echo "  make full            - Backup then restore (or backup + rsync if REMOTE_BACKUP_PATH set)"
	@echo "  make backup-all      - Backup all DBs in configs/*.env and push to S3 (for cron)"
	@echo "  make cron-backup    - Same as backup-all; use in cron at midnight"
	@echo "  make backup-xtra    - Physical backup via Percona XtraBackup"
	@echo "  make restore-xtra    - Restore from XtraBackup (use: make restore-xtra BACKUP_PATH=./backups/xtra_*)"
	@echo "  make check           - Verify config.env exists and tools (mydumper/myloader) available"
	@echo "  make clean           - Remove ./backups directory"
	@echo ""

config:
	@if [ ! -f config.env ]; then cp config.example.env config.env && echo "Created config.env - edit with your SOURCE_* and TARGET_* settings."; else echo "config.env already exists."; fi

check: config
	@test -f config.env || (echo "Run: make config" && exit 1)
	@command -v mydumper >/dev/null 2>&1 && command -v myloader >/dev/null 2>&1 && echo "mydumper/myloader OK" || echo "Warning: mydumper/myloader not found - will fall back to mysqldump (slower)"

backup: check
	./workflow.sh backup-only

restore: check
	@test -n "$(BACKUP_PATH)" || (echo "Usage: make restore BACKUP_PATH=./backups/yourdb_20250223_120000 or BACKUP_PATH=s3://bucket/prefix/yourdb_20250223_120000.tar.gz" && exit 1)
	@echo "$(BACKUP_PATH)" | grep -q '^s3://' || test -d "$(BACKUP_PATH)" || (echo "Local path not found: $(BACKUP_PATH)" && exit 1)
	./workflow.sh restore-only "$(BACKUP_PATH)"

full: check
	./workflow.sh full

backup-all cron-backup:
	./cron-backup-all.sh

backup-xtra: check
	./backup-xtrabackup.sh

restore-xtra:
	@test -n "$(BACKUP_PATH)" || (echo "Usage: make restore-xtra BACKUP_PATH=./backups/xtra_YYYYMMDD_HHMMSS" && exit 1)
	@test -d "$(BACKUP_PATH)" || (echo "Directory not found: $(BACKUP_PATH)" && exit 1)
	./restore-xtrabackup.sh "$(BACKUP_PATH)"

clean:
	rm -rf backups
	@echo "Removed ./backups"
