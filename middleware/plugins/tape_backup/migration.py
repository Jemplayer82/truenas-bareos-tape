"""
Database migration for tape_backup middleware plugin.

Creates the following tables in TrueNAS's SQLite database:
- tape_backup_bareos_config: Bareos daemon configuration and passwords
- tape_backup_job: Backup job definitions
"""

SQL_MIGRATIONS = [
    # Migration 001: Initial schema
    """
    CREATE TABLE IF NOT EXISTS tape_backup_bareos_config (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        dir_name VARCHAR(120) DEFAULT 'bareos-dir',
        dir_password VARCHAR(255) DEFAULT '',
        sd_password VARCHAR(255) DEFAULT '',
        fd_password VARCHAR(255) DEFAULT '',
        console_password VARCHAR(255) DEFAULT '',
        db_host VARCHAR(120) DEFAULT 'localhost',
        db_name VARCHAR(120) DEFAULT 'bareos',
        db_user VARCHAR(120) DEFAULT 'bareos',
        db_password VARCHAR(255) DEFAULT '',
        media_type VARCHAR(30) DEFAULT 'LTO-8',
        use_autochanger BOOLEAN DEFAULT 0,
        changer_device VARCHAR(255) DEFAULT '',
        changer_slots INTEGER DEFAULT 24,
        drives TEXT DEFAULT '[]',
        tape_server_address VARCHAR(255) DEFAULT '',
        tape_server_sd_port INTEGER DEFAULT 9103,
        nst_device VARCHAR(255) DEFAULT '/dev/nst0',
        smtp_host VARCHAR(255) DEFAULT '',
        admin_email VARCHAR(255) DEFAULT '',
        initialized BOOLEAN DEFAULT 0
    );
    """,
    """
    CREATE TABLE IF NOT EXISTS tape_backup_job (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        tape_job_name VARCHAR(200) NOT NULL UNIQUE,
        tape_job_source_paths TEXT DEFAULT '[]',
        tape_job_exclude_patterns TEXT DEFAULT '["*.tmp", "*.swp", ".Trash*"]',
        tape_job_schedule VARCHAR(255) DEFAULT '',
        tape_job_level VARCHAR(30) DEFAULT 'Incremental',
        tape_job_pool VARCHAR(120) DEFAULT 'Daily',
        tape_job_full_pool VARCHAR(120) DEFAULT 'Monthly',
        tape_job_differential_pool VARCHAR(120) DEFAULT 'Weekly',
        tape_job_incremental_pool VARCHAR(120) DEFAULT 'Daily',
        tape_job_compression BOOLEAN DEFAULT 1,
        tape_job_compression_algo VARCHAR(20) DEFAULT 'LZ4',
        tape_job_signature BOOLEAN DEFAULT 1,
        tape_job_priority INTEGER DEFAULT 10,
        tape_job_max_concurrent_jobs INTEGER DEFAULT 1,
        tape_job_enabled BOOLEAN DEFAULT 1,
        tape_job_pre_script TEXT DEFAULT '',
        tape_job_post_script TEXT DEFAULT '',
        tape_job_description TEXT DEFAULT ''
    );
    """,
    # Insert default config row if not exists
    """
    INSERT OR IGNORE INTO tape_backup_bareos_config (id) VALUES (1);
    """,
]


async def migrate(middleware):
    """Run database migrations for the tape_backup plugin."""
    for sql in SQL_MIGRATIONS:
        try:
            await middleware.call('datastore.sql', sql.strip())
        except Exception as e:
            middleware.logger.debug('tape_backup migration: %s (may already exist)', e)
