import json
import os
import secrets
import subprocess
from pathlib import Path

from jinja2 import Environment, FileSystemLoader

from middlewared.service import CallError, Service, private

BAREOS_CONFIG_DIR = '/etc/bareos'
BAREOS_SD_CONFIG_DIR = f'{BAREOS_CONFIG_DIR}/bareos-sd.d'
BAREOS_DIR_CONFIG_DIR = f'{BAREOS_CONFIG_DIR}/bareos-dir.d'
BAREOS_FD_CONFIG_DIR = f'{BAREOS_CONFIG_DIR}/bareos-fd.d'
BAREOS_SCRIPTS_DIR = '/usr/lib/bareos/scripts'

TEMPLATE_DIR = Path(__file__).parent / 'config_templates'

SYSTEMD_SERVICES = {
    'director': 'bareos-dir',
    'storage': 'bareos-sd',
    'filedaemon': 'bareos-fd',
}

LTO_CAPACITY = {
    'LTO-5': '1500G',
    'LTO-6': '2500G',
    'LTO-7': '6000G',
    'LTO-8': '12000G',
    'LTO-9': '18000G',
}


class TapeBackupBareosService(Service):

    class Config:
        namespace = 'tape_backup.bareos'
        cli_namespace = 'tape_backup.bareos'
        private = False

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self._jinja_env = None

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
        tmpl = self.jinja_env().get_template(template_name)
        return tmpl.render(context)

    @private
    async def get_config(self):
        """Retrieve stored Bareos configuration from TrueNAS database."""
        config = await self.middleware.call('datastore.config', 'tape_backup_bareos_config')
        return config

    @private
    async def save_config(self, data):
        """Save Bareos configuration to TrueNAS database."""
        existing = await self.middleware.call('datastore.config', 'tape_backup_bareos_config')
        if existing:
            await self.middleware.call('datastore.update', 'tape_backup_bareos_config', existing['id'], data)
        else:
            await self.middleware.call('datastore.insert', 'tape_backup_bareos_config', data)

    @private
    async def ensure_passwords(self):
        """Generate and store passwords for Bareos daemons if not already set."""
        config = await self.get_config()
        changed = False
        for key in ('dir_password', 'sd_password', 'fd_password', 'console_password', 'db_password'):
            if not config.get(key):
                config[key] = secrets.token_hex(32)
                changed = True
        if changed:
            await self.save_config(config)
        return config

    async def status(self):
        """Return running state of all Bareos daemons."""
        result = {}
        for name, unit in SYSTEMD_SERVICES.items():
            cp = subprocess.run(
                ['systemctl', 'is-active', unit],
                capture_output=True, text=True,
            )
            result[name] = {
                'service': unit,
                'state': cp.stdout.strip(),
                'running': cp.returncode == 0,
            }
        return result

    async def start(self):
        """Start all Bareos daemons."""
        for name, unit in SYSTEMD_SERVICES.items():
            cp = subprocess.run(
                ['systemctl', 'start', unit],
                capture_output=True, text=True,
            )
            if cp.returncode != 0:
                raise CallError(f'Failed to start {unit}: {cp.stderr}')
        return await self.status()

    async def stop(self):
        """Stop all Bareos daemons."""
        for unit in reversed(list(SYSTEMD_SERVICES.values())):
            subprocess.run(['systemctl', 'stop', unit], capture_output=True, text=True)
        return await self.status()

    async def restart(self):
        """Restart all Bareos daemons."""
        await self.stop()
        return await self.start()

    async def setup(self, job):
        """First-time Bareos setup: initialize database, generate configs, start services."""
        job.set_progress(0, 'Checking Bareos installation')

        if not os.path.exists('/usr/sbin/bareos-dir'):
            raise CallError(
                'Bareos is not installed. Run the install script first: '
                '/opt/truenas-bareos-tape/install/install.sh'
            )

        job.set_progress(10, 'Generating passwords')
        config = await self.ensure_passwords()

        job.set_progress(20, 'Initializing PostgreSQL database')
        await self._init_database(config)

        job.set_progress(40, 'Generating Bareos configuration files')
        drives = await self.middleware.call('tape_backup.drive.query')
        jobs_list = await self.middleware.call('tape_backup.job.query')
        await self.generate_config(config, drives, jobs_list)

        job.set_progress(70, 'Enabling systemd services')
        for unit in SYSTEMD_SERVICES.values():
            subprocess.run(['systemctl', 'enable', unit], capture_output=True, text=True)

        job.set_progress(80, 'Starting Bareos services')
        await self.start()

        job.set_progress(100, 'Bareos setup complete')
        return True

    @private
    async def _init_database(self, config):
        """Initialize the Bareos PostgreSQL catalog database."""
        db_password = config.get('db_password', '')

        env = os.environ.copy()
        env['PGPASSWORD'] = db_password

        for script in ('create_bareos_database', 'make_bareos_tables', 'grant_bareos_privileges'):
            script_path = f'{BAREOS_SCRIPTS_DIR}/{script}'
            if os.path.exists(script_path):
                cp = subprocess.run(
                    [script_path, 'postgresql'],
                    capture_output=True, text=True, env=env,
                )
                if cp.returncode != 0:
                    self.logger.warning('Database script %s: %s', script, cp.stderr)

    @private
    async def generate_config(self, config=None, drives=None, jobs_list=None):
        """Render all Bareos configuration files from Jinja2 templates."""
        if config is None:
            config = await self.get_config()
        if drives is None:
            drives = await self.middleware.call('tape_backup.drive.query')
        if jobs_list is None:
            jobs_list = await self.middleware.call('tape_backup.job.query')

        hostname = (await self.middleware.call('system.hostname'))
        media_type = config.get('media_type', 'LTO-8')
        max_volume_bytes = LTO_CAPACITY.get(media_type, '12000G')

        context = {
            'hostname': hostname,
            'dir_name': config.get('dir_name', 'bareos-dir'),
            'dir_password': config.get('dir_password', ''),
            'sd_password': config.get('sd_password', ''),
            'fd_password': config.get('fd_password', ''),
            'console_password': config.get('console_password', ''),
            'db_host': config.get('db_host', 'localhost'),
            'db_name': config.get('db_name', 'bareos'),
            'db_user': config.get('db_user', 'bareos'),
            'db_password': config.get('db_password', ''),
            'media_type': media_type,
            'max_volume_bytes': max_volume_bytes,
            'drives': drives,
            'use_autochanger': config.get('use_autochanger', False),
            'changer_device': config.get('changer_device', ''),
            'changer_slots': config.get('changer_slots', 24),
            'jobs': jobs_list,
        }

        self._write_config(f'{BAREOS_DIR_CONFIG_DIR}/director/bareos-dir.conf',
                           'bareos-dir.conf.j2', context)

        self._write_config(f'{BAREOS_DIR_CONFIG_DIR}/catalog/MyCatalog.conf',
                           'catalog.conf.j2', context)

        self._write_config(f'{BAREOS_DIR_CONFIG_DIR}/storage/TapeStorage.conf',
                           'storage.conf.j2', context)

        self._write_config(f'{BAREOS_DIR_CONFIG_DIR}/client/bareos-fd.conf',
                           'client.conf.j2', context)

        self._write_config(f'{BAREOS_DIR_CONFIG_DIR}/console/admin.conf',
                           'console.conf.j2', context)

        self._write_config(f'{BAREOS_DIR_CONFIG_DIR}/profile/webui-admin.conf',
                           'profile.conf.j2', context)

        for pool_name in ('Daily', 'Weekly', 'Monthly', 'Scratch'):
            pool_ctx = {**context, 'pool_name': pool_name}
            self._write_config(
                f'{BAREOS_DIR_CONFIG_DIR}/pool/{pool_name}.conf',
                'pool.conf.j2', pool_ctx,
            )

        self._write_config(f'{BAREOS_DIR_CONFIG_DIR}/schedule/TapeSchedule.conf',
                           'schedule.conf.j2', context)

        self._write_config(f'{BAREOS_DIR_CONFIG_DIR}/messages/Standard.conf',
                           'messages.conf.j2', context)

        for job_def in jobs_list:
            job_ctx = {**context, 'job': job_def}
            self._write_config(
                f'{BAREOS_DIR_CONFIG_DIR}/fileset/{job_def["name"]}.conf',
                'fileset.conf.j2', job_ctx,
            )
            self._write_config(
                f'{BAREOS_DIR_CONFIG_DIR}/job/{job_def["name"]}.conf',
                'job.conf.j2', job_ctx,
            )

        self._write_config(f'{BAREOS_DIR_CONFIG_DIR}/job/RestoreFiles.conf',
                           'restore_job.conf.j2', context)

        self._write_config(f'{BAREOS_SD_CONFIG_DIR}/director/bareos-dir.conf',
                           'bareos-sd.conf.j2', context)

        self._write_config(f'{BAREOS_SD_CONFIG_DIR}/storage/bareos-sd.conf',
                           'sd-storage.conf.j2', context)

        for idx, drive in enumerate(drives):
            drive_ctx = {**context, 'drive': drive, 'drive_index': idx}
            self._write_config(
                f'{BAREOS_SD_CONFIG_DIR}/device/TapeDrive-{idx}.conf',
                'device.conf.j2', drive_ctx,
            )

        if context['use_autochanger']:
            self._write_config(
                f'{BAREOS_SD_CONFIG_DIR}/autochanger/TapeChanger.conf',
                'autochanger.conf.j2', context,
            )

        self._write_config(f'{BAREOS_FD_CONFIG_DIR}/director/bareos-dir.conf',
                           'bareos-fd.conf.j2', context)

        self._write_config(f'{BAREOS_FD_CONFIG_DIR}/client/myself.conf',
                           'fd-client.conf.j2', context)

    @private
    def _write_config(self, dest_path, template_name, context):
        """Render a template and write to destination, creating directories as needed."""
        os.makedirs(os.path.dirname(dest_path), exist_ok=True)
        content = self.render_template(template_name, context)
        with open(dest_path, 'w') as f:
            f.write(content)
        os.chmod(dest_path, 0o640)

    @private
    async def get_connection(self):
        """Return connection parameters for python-bareos DirectorConsoleJson."""
        config = await self.get_config()
        return {
            'address': 'localhost',
            'port': 9101,
            'name': 'admin',
            'password': config.get('console_password', ''),
        }
