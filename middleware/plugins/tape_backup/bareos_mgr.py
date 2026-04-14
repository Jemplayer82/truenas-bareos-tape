"""
TapeBackupBareosService
-----------------------
Manages Bareos configuration generation and provides connection parameters
for python-bareos.  Container lifecycle is handled by the TrueNAS
bareos-tape app (docker-compose).  This service does NOT start or pull
containers — install the TrueNAS app first, then run install.sh.
"""
import os
import secrets
import subprocess
import time
from pathlib import Path

from jinja2 import Environment, FileSystemLoader

from middlewared.service import CallError, Service, job, private

BAREOS_CONFIG_DIR = '/mnt/bareos/config'
BAREOS_DATA_DIR = '/mnt/bareos/data'
BAREOS_LOG_DIR = '/mnt/bareos/logs'

TEMPLATE_DIR = Path(__file__).parent / 'config_templates'

# Container names — must match the TrueNAS app docker-compose template
CONTAINER_NAMES = {
    'director':   'bareos-dir',
    'storage':    'bareos-sd',
    'filedaemon': 'bareos-fd',
    'database':   'bareos-db',
}

LTO_CAPACITY = {
    'LTO-5': '1500G',
    'LTO-6': '2500G',
    'LTO-7': '6000G',
    'LTO-8': '12000G',
    'LTO-9': '18000G',
}


def _run(cmd, check=True, capture=True):
    return subprocess.run(cmd, check=check, capture_output=capture, text=True)


class TapeBackupBareosService(Service):

    class Config:
        namespace = 'tape_backup.bareos'
        cli_namespace = 'tape_backup.bareos'
        private = False

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self._jinja_env = None

    # ------------------------------------------------------------------ #
    #  Jinja2
    # ------------------------------------------------------------------ #

    @private
    def jinja_env(self):
        if self._jinja_env is None:
            self._jinja_env = Environment(
                loader=FileSystemLoader(str(TEMPLATE_DIR)),
                keep_trailing_newline=True,
            )
        return self._jinja_env

    @private
    def render_template(self, template_name, context):
        return self.jinja_env().get_template(template_name).render(context)

    # ------------------------------------------------------------------ #
    #  Config persistence
    # ------------------------------------------------------------------ #

    @private
    async def get_config(self):
        return await self.middleware.call('datastore.config', 'tape_backup_bareos_config')

    @private
    async def save_config(self, data):
        existing = await self.get_config()
        if existing:
            await self.middleware.call(
                'datastore.update', 'tape_backup_bareos_config', existing['id'], data
            )
        else:
            await self.middleware.call('datastore.insert', 'tape_backup_bareos_config', data)

    @private
    async def ensure_passwords(self):
        config = await self.get_config()
        changed = False
        for key in ('dir_password', 'sd_password', 'fd_password', 'console_password', 'db_password'):
            if not config.get(key):
                config[key] = secrets.token_hex(32)
                changed = True
        if changed:
            await self.save_config(config)
        return config

    # ------------------------------------------------------------------ #
    #  Container status (read-only — app manages lifecycle)
    # ------------------------------------------------------------------ #

    @private
    def _container_running(self, name):
        result = _run(
            ['docker', 'inspect', '--format', '{{.State.Running}}', name],
            check=False,
        )
        return result.returncode == 0 and result.stdout.strip() == 'true'

    async def status(self):
        """Return running state of each Bareos container managed by the app."""
        result = {}
        for role, cname in CONTAINER_NAMES.items():
            running = self._container_running(cname)
            result[role] = {
                'container': cname,
                'running': running,
                'state': 'running' if running else 'stopped',
            }
        return result

    # ------------------------------------------------------------------ #
    #  First-time setup (config generation + DB init)
    # ------------------------------------------------------------------ #

    @job(lock='bareos_setup')
    async def setup(self, job):
        """
        Generate Bareos config files and initialise the catalog DB.
        Requires the bareos-tape TrueNAS app to already be running.
        """
        job.set_progress(0, 'Checking Bareos containers')
        for role, cname in CONTAINER_NAMES.items():
            if not self._container_running(cname):
                raise CallError(
                    f'Container {cname!r} is not running. '
                    'Install and start the bareos-tape TrueNAS app first.'
                )

        job.set_progress(10, 'Generating passwords')
        config = await self.ensure_passwords()

        job.set_progress(20, 'Creating config directories')
        self._create_dirs()

        job.set_progress(30, 'Generating Bareos configuration files')
        drives = await self.middleware.call('tape_backup.drive.query')
        jobs_list = await self.middleware.call('tape_backup.job.query')
        await self.generate_config(config, drives, jobs_list)

        job.set_progress(60, 'Waiting for Director to accept connections')
        self._wait_for_director()

        job.set_progress(75, 'Initialising Bareos catalog database')
        self._init_database()

        job.set_progress(100, 'Bareos setup complete')
        await self.save_config({**config, 'initialized': True})
        return True

    # ------------------------------------------------------------------ #
    #  Config file generation
    # ------------------------------------------------------------------ #

    @private
    def _create_dirs(self):
        for path in (BAREOS_CONFIG_DIR, BAREOS_DATA_DIR, BAREOS_LOG_DIR):
            os.makedirs(path, exist_ok=True)

        for subdir in ('bareos-dir.d', 'bareos-sd.d', 'bareos-fd.d'):
            os.makedirs(f'{BAREOS_CONFIG_DIR}/{subdir}', exist_ok=True)

        for sub in ('director', 'catalog', 'storage', 'client', 'console',
                    'profile', 'pool', 'schedule', 'messages', 'job', 'fileset'):
            os.makedirs(f'{BAREOS_CONFIG_DIR}/bareos-dir.d/{sub}', exist_ok=True)

        for sub in ('director', 'storage', 'device', 'autochanger', 'messages'):
            os.makedirs(f'{BAREOS_CONFIG_DIR}/bareos-sd.d/{sub}', exist_ok=True)

        for sub in ('director', 'client', 'messages'):
            os.makedirs(f'{BAREOS_CONFIG_DIR}/bareos-fd.d/{sub}', exist_ok=True)

    @private
    async def generate_config(self, config=None, drives=None, jobs_list=None):
        if config is None:
            config = await self.get_config()
        if drives is None:
            drives = await self.middleware.call('tape_backup.drive.query')
        if jobs_list is None:
            jobs_list = await self.middleware.call('tape_backup.job.query')

        hostname = await self.middleware.call('system.hostname')
        media_type = config.get('media_type', 'LTO-8')

        context = {
            'hostname': hostname,
            'dir_name': config.get('dir_name', 'bareos-dir'),
            'dir_password': config.get('dir_password', ''),
            'sd_password': config.get('sd_password', ''),
            'fd_password': config.get('fd_password', ''),
            'console_password': config.get('console_password', ''),
            'db_host': CONTAINER_NAMES['database'],
            'db_name': 'bareos',
            'db_user': 'bareos',
            'db_password': config.get('db_password', ''),
            'media_type': media_type,
            'max_volume_bytes': LTO_CAPACITY.get(media_type, '12000G'),
            'drives': drives,
            'use_autochanger': config.get('use_autochanger', False),
            'changer_device': config.get('changer_device', ''),
            'changer_slots': config.get('changer_slots', 24),
            'jobs': jobs_list,
            'sd_address': CONTAINER_NAMES['storage'],
            'fd_address': CONTAINER_NAMES['filedaemon'],
            'admin_email': config.get('admin_email', ''),
        }

        self._create_dirs()

        mappings = [
            (f'{BAREOS_CONFIG_DIR}/bareos-dir.d/director/bareos-dir.conf',   'bareos-dir.conf.j2'),
            (f'{BAREOS_CONFIG_DIR}/bareos-dir.d/catalog/MyCatalog.conf',     'catalog.conf.j2'),
            (f'{BAREOS_CONFIG_DIR}/bareos-dir.d/storage/TapeStorage.conf',   'storage.conf.j2'),
            (f'{BAREOS_CONFIG_DIR}/bareos-dir.d/client/bareos-fd.conf',      'client.conf.j2'),
            (f'{BAREOS_CONFIG_DIR}/bareos-dir.d/console/admin.conf',         'console.conf.j2'),
            (f'{BAREOS_CONFIG_DIR}/bareos-dir.d/profile/webui-admin.conf',   'profile.conf.j2'),
            (f'{BAREOS_CONFIG_DIR}/bareos-dir.d/schedule/TapeSchedule.conf', 'schedule.conf.j2'),
            (f'{BAREOS_CONFIG_DIR}/bareos-dir.d/messages/Standard.conf',     'messages.conf.j2'),
            (f'{BAREOS_CONFIG_DIR}/bareos-dir.d/job/RestoreFiles.conf',      'restore_job.conf.j2'),
            (f'{BAREOS_CONFIG_DIR}/bareos-sd.d/director/bareos-dir.conf',    'bareos-sd.conf.j2'),
            (f'{BAREOS_CONFIG_DIR}/bareos-sd.d/storage/bareos-sd.conf',      'sd-storage.conf.j2'),
            (f'{BAREOS_CONFIG_DIR}/bareos-fd.d/director/bareos-dir.conf',    'bareos-fd.conf.j2'),
            (f'{BAREOS_CONFIG_DIR}/bareos-fd.d/client/myself.conf',          'fd-client.conf.j2'),
        ]

        for dest, tmpl in mappings:
            self._write_config(dest, tmpl, context)

        for pool_name in ('Daily', 'Weekly', 'Monthly', 'Scratch'):
            self._write_config(
                f'{BAREOS_CONFIG_DIR}/bareos-dir.d/pool/{pool_name}.conf',
                'pool.conf.j2', {**context, 'pool_name': pool_name},
            )

        for job_def in jobs_list:
            job_ctx = {**context, 'job': job_def}
            self._write_config(
                f'{BAREOS_CONFIG_DIR}/bareos-dir.d/fileset/{job_def["name"]}.conf',
                'fileset.conf.j2', job_ctx,
            )
            self._write_config(
                f'{BAREOS_CONFIG_DIR}/bareos-dir.d/job/{job_def["name"]}.conf',
                'job.conf.j2', job_ctx,
            )

        tape_drives = [d for d in drives if d.get('type') == 'tape']
        for idx, drive in enumerate(tape_drives):
            self._write_config(
                f'{BAREOS_CONFIG_DIR}/bareos-sd.d/device/TapeDrive-{idx}.conf',
                'device.conf.j2', {**context, 'drive': drive, 'drive_index': idx},
            )

        if context['use_autochanger']:
            self._write_config(
                f'{BAREOS_CONFIG_DIR}/bareos-sd.d/autochanger/TapeChanger.conf',
                'autochanger.conf.j2', context,
            )

    @private
    def _write_config(self, dest_path, template_name, context):
        os.makedirs(os.path.dirname(dest_path), exist_ok=True)
        content = self.render_template(template_name, context)
        with open(dest_path, 'w') as f:
            f.write(content)
        os.chmod(dest_path, 0o640)

    # ------------------------------------------------------------------ #
    #  DB initialisation (run once after first app start)
    # ------------------------------------------------------------------ #

    @private
    def _wait_for_director(self, timeout=120):
        deadline = time.time() + timeout
        while time.time() < deadline:
            result = _run(
                ['docker', 'exec', CONTAINER_NAMES['director'],
                 'bareos-dir', '-t'],
                check=False,
            )
            if result.returncode == 0:
                return
            time.sleep(5)
        self.logger.warning('Timed out waiting for Bareos Director')

    @private
    def _init_database(self):
        for script in ('create_bareos_database', 'make_bareos_tables', 'grant_bareos_privileges'):
            _run(
                ['docker', 'exec', CONTAINER_NAMES['director'],
                 f'/usr/lib/bareos/scripts/{script}', 'postgresql'],
                check=False,
            )

    # ------------------------------------------------------------------ #
    #  python-bareos connection params
    # ------------------------------------------------------------------ #

    @private
    async def get_connection(self):
        config = await self.get_config()
        return {
            'address': '127.0.0.1',
            'port': 9101,
            'name': 'admin',
            'password': config.get('console_password', ''),
        }
