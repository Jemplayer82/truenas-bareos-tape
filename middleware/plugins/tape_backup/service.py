import json

import bareos.bsock

from middlewared.schema import accepts, Bool, Dict, Int, List, Patch, returns, Str
from middlewared.service import CallError, CRUDService, job, private
from middlewared.utils import filter_list


class TapeBackupJobModel:
    """Describes the tape_backup_job datastore schema."""
    pass


class TapeBackupJobService(CRUDService):

    class Config:
        namespace = 'tape_backup.job'
        cli_namespace = 'tape_backup.job'
        datastore = 'tape_backup_job'
        datastore_prefix = 'tape_job_'
        private = False
        role_prefix = 'TAPE_BACKUP'

    ENTRY = Dict(
        'tape_backup_job_entry',
        Int('id'),
        Str('name', required=True),
        List('source_paths', items=[Str('path')], required=True),
        List('exclude_patterns', items=[Str('pattern')], default=['*.tmp', '*.swp', '.Trash*']),
        Str('schedule', default=''),
        Str('level', enum=['Full', 'Incremental', 'Differential'], default='Incremental'),
        Str('pool', default='Daily'),
        Str('full_pool', default='Monthly'),
        Str('differential_pool', default='Weekly'),
        Str('incremental_pool', default='Daily'),
        Bool('compression', default=True),
        Str('compression_algo', enum=['LZ4', 'GZIP', 'LZO', 'LZFAST', 'None'], default='LZ4'),
        Bool('signature', default=True),
        Int('priority', default=10),
        Int('max_concurrent_jobs', default=1),
        Bool('enabled', default=True),
        Str('pre_script', default=''),
        Str('post_script', default=''),
        Str('description', default=''),
    )

    @accepts(
        Dict(
            'tape_backup_job_create',
            Str('name', required=True),
            List('source_paths', items=[Str('path')], required=True),
            List('exclude_patterns', items=[Str('pattern')]),
            Str('schedule'),
            Str('level', enum=['Full', 'Incremental', 'Differential']),
            Str('pool'),
            Str('full_pool'),
            Str('differential_pool'),
            Str('incremental_pool'),
            Bool('compression'),
            Str('compression_algo', enum=['LZ4', 'GZIP', 'LZO', 'LZFAST', 'None']),
            Bool('signature'),
            Int('priority'),
            Int('max_concurrent_jobs'),
            Bool('enabled'),
            Str('pre_script'),
            Str('post_script'),
            Str('description'),
        )
    )
    async def do_create(self, data):
        """Create a new tape backup job definition."""
        existing = await self.query([['name', '=', data['name']]])
        if existing:
            raise CallError(f'A job with name "{data["name"]}" already exists')

        if not data.get('source_paths'):
            raise CallError('At least one source path is required')

        job_id = await self.middleware.call('datastore.insert', self._config.datastore, data)

        await self.middleware.call('tape_backup.bareos.generate_config')

        status = await self.middleware.call('tape_backup.bareos.status')
        if status.get('director', {}).get('running'):
            await self._reload_director()

        return await self.get_instance(job_id)

    @accepts(
        Int('id'),
        Patch('tape_backup_job_create', 'tape_backup_job_update', ('attr', {'update': True})),
    )
    async def do_update(self, id_, data):
        """Update an existing tape backup job definition."""
        old = await self.get_instance(id_)
        new = old.copy()
        new.update(data)

        if 'name' in data and data['name'] != old['name']:
            existing = await self.query([['name', '=', data['name']]])
            if existing:
                raise CallError(f'A job with name "{data["name"]}" already exists')

        await self.middleware.call('datastore.update', self._config.datastore, id_, new)

        await self.middleware.call('tape_backup.bareos.generate_config')

        status = await self.middleware.call('tape_backup.bareos.status')
        if status.get('director', {}).get('running'):
            await self._reload_director()

        return await self.get_instance(id_)

    @accepts(Int('id'))
    async def do_delete(self, id_):
        """Delete a tape backup job definition."""
        await self.get_instance(id_)
        result = await self.middleware.call('datastore.delete', self._config.datastore, id_)

        await self.middleware.call('tape_backup.bareos.generate_config')

        status = await self.middleware.call('tape_backup.bareos.status')
        if status.get('director', {}).get('running'):
            await self._reload_director()

        return result

    @accepts(Int('id'))
    @job(logs=True)
    async def run(self, job, id_):
        """Execute a tape backup job immediately."""
        job_def = await self.get_instance(id_)

        job.set_progress(0, f'Starting backup job: {job_def["name"]}')

        conn_params = await self.middleware.call('tape_backup.bareos.get_connection')

        try:
            director = bareos.bsock.DirectorConsoleJson(
                address=conn_params['address'],
                port=conn_params['port'],
                name=conn_params['name'],
                password=bareos.bsock.Password(conn_params['password']),
            )
        except Exception as e:
            raise CallError(f'Failed to connect to Bareos Director: {e}')

        try:
            result = director.call(f'run job="{job_def["name"]}" level={job_def["level"]} yes')
            job.set_progress(10, f'Job submitted to Bareos: {result}')

            job_id_match = None
            if isinstance(result, dict):
                job_id_match = result.get('jobid')
            elif isinstance(result, str):
                import re
                m = re.search(r'JobId=(\d+)', result)
                if m:
                    job_id_match = int(m.group(1))

            if job_id_match:
                await self._monitor_bareos_job(job, director, job_id_match, job_def['name'])
            else:
                job.set_progress(100, f'Job submitted (could not track ID): {result}')

        except Exception as e:
            raise CallError(f'Failed to run backup job: {e}')
        finally:
            director.disconnect()

        return True

    @accepts(Dict(
        'tape_restore_params',
        Int('job_id'),
        Str('client', default='bareos-fd'),
        List('file_list', items=[Str('file_path')]),
        Str('destination', required=True),
        Str('replace', enum=['always', 'ifnewer', 'ifolder', 'never'], default='never'),
        Str('restore_job', default='RestoreFiles'),
    ))
    @job(logs=True)
    async def restore(self, job, data):
        """Restore files from tape backup."""
        job.set_progress(0, 'Connecting to Bareos Director')

        conn_params = await self.middleware.call('tape_backup.bareos.get_connection')

        try:
            director = bareos.bsock.DirectorConsoleJson(
                address=conn_params['address'],
                port=conn_params['port'],
                name=conn_params['name'],
                password=bareos.bsock.Password(conn_params['password']),
            )
        except Exception as e:
            raise CallError(f'Failed to connect to Bareos Director: {e}')

        try:
            job.set_progress(10, 'Building file list for restore')

            if data.get('file_list'):
                file_list_str = '\n'.join(data['file_list'])
                result = director.call(
                    f'restore client={data["client"]} '
                    f'where="{data["destination"]}" '
                    f'replace={data["replace"]} '
                    f'file="{file_list_str}" '
                    f'yes'
                )
            else:
                result = director.call(
                    f'restore client={data["client"]} '
                    f'where="{data["destination"]}" '
                    f'replace={data["replace"]} '
                    f'select all done yes'
                )

            job.set_progress(20, f'Restore job submitted: {result}')

            bareos_job_id = None
            if isinstance(result, dict):
                bareos_job_id = result.get('jobid')

            if bareos_job_id:
                await self._monitor_bareos_job(job, director, bareos_job_id, 'RestoreFiles')

            job.set_progress(100, 'Restore complete')

        except Exception as e:
            raise CallError(f'Restore failed: {e}')
        finally:
            director.disconnect()

        return True

    @private
    async def _monitor_bareos_job(self, job, director, bareos_job_id, job_name):
        """Poll Bareos job status until completion."""
        import asyncio

        max_polls = 3600
        for i in range(max_polls):
            try:
                status = director.call(f'list jobid={bareos_job_id}')

                job_status = None
                job_bytes = 0
                job_files = 0

                if isinstance(status, dict) and 'jobs' in status:
                    jobs = status['jobs']
                    if jobs:
                        j = jobs[0] if isinstance(jobs, list) else jobs
                        job_status = j.get('jobstatus', '')
                        job_bytes = int(j.get('jobbytes', 0))
                        job_files = int(j.get('jobfiles', 0))

                if job_status in ('T', 'W'):
                    job.set_progress(
                        100,
                        f'Job {job_name} completed. Files: {job_files}, Bytes: {job_bytes}'
                    )
                    return
                elif job_status in ('E', 'e', 'f', 'A'):
                    raise CallError(
                        f'Bareos job {job_name} (ID {bareos_job_id}) failed with status: {job_status}'
                    )
                else:
                    progress = min(90, 10 + i // 4)
                    job.set_progress(
                        progress,
                        f'Running {job_name}: {job_files} files, {job_bytes} bytes written'
                    )

            except CallError:
                raise
            except Exception:
                pass

            await asyncio.sleep(2)

        raise CallError(f'Timeout waiting for Bareos job {bareos_job_id} to complete')

    @private
    async def _reload_director(self):
        """Send reload command to running Bareos Director."""
        try:
            conn_params = await self.middleware.call('tape_backup.bareos.get_connection')
            director = bareos.bsock.DirectorConsoleJson(
                address=conn_params['address'],
                port=conn_params['port'],
                name=conn_params['name'],
                password=bareos.bsock.Password(conn_params['password']),
            )
            director.call('reload')
            director.disconnect()
        except Exception as e:
            self.logger.warning('Failed to reload Bareos Director: %s', e)
