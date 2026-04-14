import json
import os
import secrets
import subprocess
import time
from pathlib import Path

from jinja2 import Environment, FileSystemLoader

from middlewared.service import CallError, Service, private

BAREOS_CONFIG_DIR = '/mnt/bareos/config'
BAREOS_DATA_DIR = '/mnt/bareos/data'
BAREOS_LOG_DIR = '/mnt/bareos/logs'

TEMPLATE_DIR = Path(__file__).parent / 'config_templates'

# Official Bareos Docker images
IMAGES = {
    'director': 'bareos/bareos-director:latest',
    'storage':  'bareos/bareos-storage:latest',
    'filedaemon': 'bareos/bareos-client:latest',
    'database': 'postgres:16-bookworm',
}

CONTAINER_NAMES = {
    'director':  'bareos-dir',
    'storage':   'bareos-sd',
    'filedaemon': 'bareos-fd',
    'database':  'bareos-db',
}

NETWORK_NAME = 'bareos-net'

LTO_CAPACITY = {
    'LTO-5': '1500G',
    'LTO-6': '2500G',
    'LTO-7': '6000G',
    'LTO-8': '12000G',
    'LTO-9': '18000G',
}


def _run(cmd, check=True, capture=True):
    """Run a shell command, return CompletedProcess."""
    return subprocess.run(
        cmd, check=check,
        capture_output=capture, text=True,
    )


class TapeBackupBareosService(Service):

    class Config:
        namespace = 'tape_backup.bareos'
        cli_namespace = 'tape_backup.bareos'
        private = False

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self._jinja_env = None

    # ------------------------------------------------------------------ #
    #  Jinja2 / config generation
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
    #  Config persistence (TrueNAS SQLite)
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
    #  Docker helpers
    # ------------------------------------------------------------------ #

    @private
    def _docker(self, *args, check=True):
        return _run(['docker'] + list(args), check=check)

    @private
    def _container_running(self, name):
        result = _run(
            ['docker', 'inspect', '--format', '{{.State.Running}}', name],
            check=False,
        )
        return result.returncode == 0 and result.stdout.strip() == 'true'

    @private
    def _container_exists(self, name):
        result = _run(
            ['docker', 'inspect', '--format', '{{.Name}}', name],
            check=False,
        )
        return result.returncode == 0

    @private
    def _ensure_network(self):
        result = _run(
            ['docker', 'network', 'inspect', NETWORK_NAME],
            check=False,
        )
        if result.returncode != 0:
            _run(['docker', 'network', 'create', NETWORK_NAME])

    @private
    def _stop_container(self, name):
        if self._container_running(name):
            _run(['docker', 'stop', '-t', '30', name], check=False)
        if self._container_exists(name):
            _run(['docker', 'rm', name], check=False)

    # ------------------------------------------------------------------ #
    #  Status / start / stop
    # ------------------------------------------------------------------ #

    async def status(self):
        result = {}
        for role, cname in CONTAINER_NAMES.items():
            running = self._container_running(cname)
            result[role] = {
                'container': cname,
                'running': running,
                'state': 'running' if running else 'stopped',
            }
        return result

    async def start(self):
        config = await self.get_config()
        drives = await self.middleware.call('tape_backup.drive.query')
        await self._start_containers(config, drives)
        return await self.status()

    async def stop(self):
        for cname in reversed(list(CONTAINER_NAMES.values())):
            self._stop_container(cname)
        return await self.status()

    async def restart(self):
        await self.stop()
        return await self.start()

    # ------------------------------------------------------------------ #
    #  First-time setup
    # ------------------------------------------------------------------ #

    async def setup(self, job):
        job.set_progress(0, 'Checking Docker availability')
        try:
            _run(['docker', 'info'])
        except (FileNotFoundError, subprocess.CalledProcessError):
            raise CallError('Docker is not available on this system')

        job.set_progress(5, 'Pulling Bareos Docker images')
        await self._pull_images(job)

        job.set_progress(30, 'Generating passwords')
        config = await self.ensure_passwords()

        job.set_progress(35, 'Creating config directories')
        self._create_dirs()

        job.set_progress(40, 'Generating Bareos configuration files')
        drives = await self.middleware.call('tape_backup.drive.query')
        jobs_list = await self.middleware.call('tape_backup.job.query')
        await self.generate_config(config, drives, jobs_list)

        job.set_progress(55, 'Starting containers')
        await self._start_containers(config, drives)

        job.set_progress(75, 'Waiting for Director to be ready')
        self._wait_for_director()

        job.set_progress(85, 'Initializing Bareos database')
        self._init_database()

        job.set_progress(100, 'Bareos setup complete')
        return True

    # ------------------------------------------------------------------ #
    #  Container lifecycle internals
    # ------------------------------------------------------------------ #

    @private
    async def _pull_images(self, job=None):
        for role, image in IMAGES.items():
            if job:
                job.set_progress(5, f'Pulling {image}')
            _run(['docker', 'pull', image])

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
    async def _start_containers(self, config, drives):
        self._ensure_network()

        db_password = config.get('db_password', '')

        # --- PostgreSQL ---
        if not self._container_running(CONTAINER_NAMES['database']):
            self._stop_container(CONTAINER_NAMES['database'])
            _run([
                'docker', 'run', '-d',
                '--name', CONTAINER_NAMES['database'],
                '--network', NETWORK_NAME,
                '--restart', 'unless-stopped',
                '-e', f'POSTGRES_USER=bareos',
                '-e', f'POSTGRES_PASSWORD={db_password}',
                '-e', f'POSTGRES_DB=bareos',
                '-v', f'{BAREOS_DATA_DIR}/postgres:/var/lib/postgresql/data',
                IMAGES['database'],
            ])
            time.sleep(5)

        hostname = (await self.middleware.call('system.hostname'))

        # --- Director ---
        if not self._container_running(CONTAINER_NAMES['director']):
            self._stop_container(CONTAINER_NAMES['director'])
            _run([
                'docker', 'run', '-d',
                '--name', CONTAINER_NAMES['director'],
                '--network', NETWORK_NAME,
                '--restart', 'unless-stopped',
                '-p', '9101:9101',
                '-e', f'DB_HOST={CONTAINER_NAMES["database"]}',
                '-e', f'DB_PASSWORD={db_password}',
                '-e', f'BAREOS_SD_PASSWORD={config.get("sd_password", "")}',
                '-e', f'BAREOS_FD_PASSWORD={config.get("fd_password", "")}',
                '-e', f'BAREOS_WEBUI_PASSWORD={config.get("console_password", "")}',
                '-v', f'{BAREOS_CONFIG_DIR}/bareos-dir.d:/etc/bareos/bareos-dir.d:ro',
                '-v', f'{BAREOS_DATA_DIR}/director:/var/lib/bareos',
                IMAGES['director'],
            ])

        # --- Storage Daemon (with tape device passthrough) ---
        if not self._container_running(CONTAINER_NAMES['storage']):
            self._stop_container(CONTAINER_NAMES['storage'])
            sd_cmd = [
                'docker', 'run', '-d',
                '--name', CONTAINER_NAMES['storage'],
                '--network', NETWORK_NAME,
                '--restart', 'unless-stopped',
                '-p', '9103:9103',
                '--cap-add', 'SYS_RAWIO',
            ]
            # Pass through tape drives
            tape_drives = [d for d in drives if d['type'] == 'tape']
            for drive in tape_drives:
                dev = drive.get('nst_device') or drive.get('device')
                if dev and os.path.exists(dev):
                    sd_cmd += ['--device', f'{dev}:{dev}']
            # Pass through changers
            changer_drives = [d for d in drives if d['type'] == 'changer']
            for drive in changer_drives:
                dev = drive.get('sg_device') or drive.get('device')
                if dev and os.path.exists(dev):
                    sd_cmd += ['--device', f'{dev}:{dev}']

            sd_cmd += [
                '-e', f'BAREOS_SD_PASSWORD={config.get("sd_password", "")}',
                '-e', f'BAREOS_DIR_NAME={config.get("dir_name", "bareos-dir")}',
                '-v', f'{BAREOS_CONFIG_DIR}/bareos-sd.d:/etc/bareos/bareos-sd.d:ro',
                '-v', f'{BAREOS_DATA_DIR}/storage:/var/lib/bareos/storage',
                IMAGES['storage'],
            ]
            _run(sd_cmd)

        # --- File Daemon ---
        if not self._container_running(CONTAINER_NAMES['filedaemon']):
            self._stop_container(CONTAINER_NAMES['filedaemon'])
            fd_cmd = [
                'docker', 'run', '-d',
                '--name', CONTAINER_NAMES['filedaemon'],
                '--network', NETWORK_NAME,
                '--restart', 'unless-stopped',
                '-p', '9102:9102',
                '-e', f'BAREOS_FD_PASSWORD={config.get("fd_password", "")}',
                '-e', f'BAREOS_DIR_NAME={config.get("dir_name", "bareos-dir")}',
                '-v', f'{BAREOS_CONFIG_DIR}/bareos-fd.d:/etc/bareos/bareos-fd.d:ro',
            ]
            # Mount backup source paths
            jobs_list = await self.middleware.call('tape_backup.job.query')
            mounted = set()
            for job_def in jobs_list:
                for src in job_def.get('source_paths', []):
                    if src not in mounted and os.path.exists(src):
                        fd_cmd += ['-v', f'{src}:{src}:ro']
                        mounted.add(src)

            fd_cmd.append(IMAGES['filedaemon'])
            _run(fd_cmd)

    @private
    def _wait_for_director(self, timeout=60):
        deadline = time.time() + timeout
        while time.time() < deadline:
            result = _run(
                ['docker', 'exec', CONTAINER_NAMES['director'],
                 'bareos-dir', '-t'],
                check=False,
            )
            if result.returncode == 0:
                return
            time.sleep(3)
        self.logger.warning('Timed out waiting for Bareos Director to be ready')

    @private
    def _init_database(self):
        scripts = (
            'create_bareos_database',
            'make_bareos_tables',
            'grant_bareos_privileges',
        )
        for script in scripts:
            _run(
                ['docker', 'exec', CONTAINER_NAMES['director'],
                 f'/usr/lib/bareos/scripts/{script}', 'postgresql'],
                check=False,
            )

    # ------------------------------------------------------------------ #
    #  Config file generation
    # ------------------------------------------------------------------ #

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
            (f'{BAREOS_CONFIG_DIR}/bareos-dir.d/director/bareos-dir.conf', 'bareos-dir.conf.j2'),
            (f'{BAREOS_CONFIG_DIR}/bareos-dir.d/catalog/MyCatalog.conf', 'catalog.conf.j2'),
            (f'{BAREOS_CONFIG_DIR}/bareos-dir.d/storage/TapeStorage.conf', 'storage.conf.j2'),
            (f'{BAREOS_CONFIG_DIR}/bareos-dir.d/client/bareos-fd.conf', 'client.conf.j2'),
            (f'{BAREOS_CONFIG_DIR}/bareos-dir.d/console/admin.conf', 'console.conf.j2'),
            (f'{BAREOS_CONFIG_DIR}/bareos-dir.d/profile/webui-admin.conf', 'profile.conf.j2'),
            (f'{BAREOS_CONFIG_DIR}/bareos-dir.d/schedule/TapeSchedule.conf', 'schedule.conf.j2'),
            (f'{BAREOS_CONFIG_DIR}/bareos-dir.d/messages/Standard.conf', 'messages.conf.j2'),
            (f'{BAREOS_CONFIG_DIR}/bareos-dir.d/job/RestoreFiles.conf', 'restore_job.conf.j2'),
            (f'{BAREOS_CONFIG_DIR}/bareos-sd.d/director/bareos-dir.conf', 'bareos-sd.conf.j2'),
            (f'{BAREOS_CONFIG_DIR}/bareos-sd.d/storage/bareos-sd.conf', 'sd-storage.conf.j2'),
            (f'{BAREOS_CONFIG_DIR}/bareos-fd.d/director/bareos-dir.conf', 'bareos-fd.conf.j2'),
            (f'{BAREOS_CONFIG_DIR}/bareos-fd.d/client/myself.conf', 'fd-client.conf.j2'),
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
