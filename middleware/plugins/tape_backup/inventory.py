import subprocess

import bareos.bsock

from middlewared.schema import accepts, Dict, Int, returns, Str
from middlewared.service import CallError, job, Service, private


class TapeBackupInventoryService(Service):

    class Config:
        namespace = 'tape_backup.inventory'
        cli_namespace = 'tape_backup.inventory'
        private = False

    @private
    async def _get_director(self):
        """Get an authenticated connection to the Bareos Director."""
        conn_params = await self.middleware.call('tape_backup.bareos.get_connection')
        try:
            return bareos.bsock.DirectorConsoleJson(
                address=conn_params['address'],
                port=conn_params['port'],
                name=conn_params['name'],
                password=bareos.bsock.Password(conn_params['password']),
            )
        except Exception as e:
            raise CallError(f'Failed to connect to Bareos Director: {e}')

    async def volumes(self):
        """List all tape volumes (media) known to the Bareos catalog."""
        director = await self._get_director()
        try:
            result = director.call('list volumes')

            volumes = []
            if isinstance(result, dict):
                for pool_name, pool_volumes in result.get('volumes', {}).items():
                    if isinstance(pool_volumes, list):
                        for vol in pool_volumes:
                            volumes.append({
                                'volume_name': vol.get('volumename', vol.get('medianame', '')),
                                'pool': pool_name,
                                'media_type': vol.get('mediatype', ''),
                                'volume_status': vol.get('volstatus', ''),
                                'volume_bytes': int(vol.get('volbytes', 0)),
                                'volume_files': int(vol.get('volfiles', 0)),
                                'volume_jobs': int(vol.get('voljobs', 0)),
                                'first_written': vol.get('firstwritten', ''),
                                'last_written': vol.get('lastwritten', ''),
                                'recycle': vol.get('recycle', '') == '1',
                                'slot': int(vol.get('slot', 0)),
                                'in_changer': vol.get('inchanger', '') == '1',
                                'max_volume_bytes': int(vol.get('maxvolbytes', 0)),
                                'volume_retention': vol.get('volretention', ''),
                            })
            return volumes

        finally:
            director.disconnect()

    async def pools(self):
        """List all Bareos storage pools with statistics."""
        director = await self._get_director()
        try:
            result = director.call('list pools')

            pools = []
            if isinstance(result, dict) and 'pools' in result:
                pool_list = result['pools']
                if isinstance(pool_list, list):
                    for pool in pool_list:
                        pool_info = {
                            'pool_id': int(pool.get('poolid', 0)),
                            'name': pool.get('name', ''),
                            'num_volumes': int(pool.get('numvols', 0)),
                            'max_volumes': int(pool.get('maxvols', 0)),
                            'pool_type': pool.get('pooltype', ''),
                            'label_format': pool.get('labelformat', ''),
                            'use_catalog': pool.get('usecatalog', '') == '1',
                            'recycle': pool.get('recycle', '') == '1',
                            'auto_prune': pool.get('autoprune', '') == '1',
                            'volume_retention': pool.get('volretention', ''),
                            'max_volume_bytes': int(pool.get('maxvolbytes', 0)),
                        }

                        total_bytes = 0
                        total_files = 0
                        try:
                            vol_result = director.call(f'list volumes pool={pool_info["name"]}')
                            if isinstance(vol_result, dict):
                                for _, vols in vol_result.get('volumes', {}).items():
                                    if isinstance(vols, list):
                                        for v in vols:
                                            total_bytes += int(v.get('volbytes', 0))
                                            total_files += int(v.get('volfiles', 0))
                        except Exception:
                            pass

                        pool_info['total_bytes'] = total_bytes
                        pool_info['total_files'] = total_files
                        pools.append(pool_info)

            return pools

        finally:
            director.disconnect()

    @accepts(Dict(
        'label_params',
        Str('volume_name', required=True),
        Str('pool', required=True),
        Str('storage', default='TapeStorage'),
        Int('slot', default=0),
    ))
    @job(logs=True)
    async def label(self, job, data):
        """Label a new tape volume and assign it to a pool."""
        job.set_progress(0, f'Labeling volume {data["volume_name"]} in pool {data["pool"]}')

        director = await self._get_director()
        try:
            cmd = (
                f'label volume="{data["volume_name"]}" '
                f'pool="{data["pool"]}" '
                f'storage="{data["storage"]}"'
            )
            if data.get('slot', 0) > 0:
                cmd += f' slot={data["slot"]}'

            result = director.call(cmd)
            job.set_progress(100, f'Volume labeled: {result}')
            return {
                'volume_name': data['volume_name'],
                'pool': data['pool'],
                'result': str(result),
            }

        except Exception as e:
            raise CallError(f'Failed to label volume: {e}')
        finally:
            director.disconnect()

    @accepts(Str('volume_name'))
    async def purge(self, volume_name):
        """Purge all jobs from a volume, making it available for reuse."""
        director = await self._get_director()
        try:
            result = director.call(f'purge volume="{volume_name}" yes')
            return {'volume_name': volume_name, 'result': str(result)}
        except Exception as e:
            raise CallError(f'Failed to purge volume: {e}')
        finally:
            director.disconnect()

    @accepts(Dict(
        'move_params',
        Str('volume_name', required=True),
        Str('new_pool', required=True),
    ))
    async def move_to_pool(self, data):
        """Move a volume to a different pool."""
        director = await self._get_director()
        try:
            result = director.call(
                f'update volume="{data["volume_name"]}" pool="{data["new_pool"]}"'
            )
            return {
                'volume_name': data['volume_name'],
                'new_pool': data['new_pool'],
                'result': str(result),
            }
        except Exception as e:
            raise CallError(f'Failed to move volume: {e}')
        finally:
            director.disconnect()

    async def update_slots(self):
        """Update autochanger slot status (for tape libraries with autochangers)."""
        config = await self.middleware.call('tape_backup.bareos.get_config')

        if not config.get('use_autochanger'):
            raise CallError('Autochanger is not configured')

        changer_device = config.get('changer_device', '')
        if not changer_device:
            raise CallError('No changer device configured')

        try:
            cp = subprocess.run(
                ['mtx', '-f', changer_device, 'status'],
                capture_output=True, text=True, timeout=60,
            )
            if cp.returncode != 0:
                raise CallError(f'mtx status failed: {cp.stderr}')

            slots = self._parse_mtx_status(cp.stdout)

            director = await self._get_director()
            try:
                director.call('update slots storage=TapeStorage')
            finally:
                director.disconnect()

            return slots

        except FileNotFoundError:
            raise CallError('mtx command not found. Ensure mtx is installed.')

    @private
    def _parse_mtx_status(self, output):
        """Parse mtx status output into structured slot information."""
        slots = []
        import re

        for line in output.strip().splitlines():
            slot_match = re.match(
                r'\s*Storage Element (\d+):\s*(Full|Empty)(?:\s*:VolumeTag\s*=\s*(.+))?',
                line,
            )
            if slot_match:
                slots.append({
                    'slot': int(slot_match.group(1)),
                    'status': slot_match.group(2).lower(),
                    'volume_tag': (slot_match.group(3) or '').strip(),
                })

            drive_match = re.match(
                r'\s*Data Transfer Element (\d+):\s*(Full|Empty)(?:\s*\(Storage Element (\d+) Loaded\))?'
                r'(?::VolumeTag\s*=\s*(.+))?',
                line,
            )
            if drive_match:
                slots.append({
                    'slot': f'drive-{drive_match.group(1)}',
                    'status': drive_match.group(2).lower(),
                    'loaded_from_slot': int(drive_match.group(3)) if drive_match.group(3) else None,
                    'volume_tag': (drive_match.group(4) or '').strip(),
                    'is_drive': True,
                })

        return slots

    async def recent_jobs(self, limit=20):
        """Get recent backup/restore job results from Bareos catalog."""
        director = await self._get_director()
        try:
            result = director.call(f'list jobs limit={limit}')

            jobs = []
            if isinstance(result, dict) and 'jobs' in result:
                job_list = result['jobs']
                if isinstance(job_list, list):
                    for j in job_list:
                        jobs.append({
                            'jobid': int(j.get('jobid', 0)),
                            'name': j.get('name', ''),
                            'type': j.get('type', ''),
                            'level': j.get('level', ''),
                            'client': j.get('client', ''),
                            'job_status': j.get('jobstatus', ''),
                            'start_time': j.get('starttime', ''),
                            'end_time': j.get('endtime', ''),
                            'job_bytes': int(j.get('jobbytes', 0)),
                            'job_files': int(j.get('jobfiles', 0)),
                            'volume_name': j.get('volumename', ''),
                        })

            return jobs

        except Exception as e:
            raise CallError(f'Failed to query recent jobs: {e}')
        finally:
            director.disconnect()
