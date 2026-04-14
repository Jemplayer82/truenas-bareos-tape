import glob
import os
import re
import subprocess

from middlewared.schema import accepts, Dict, Int, returns, Str
from middlewared.service import CallError, Service, private


class TapeBackupDriveService(Service):

    class Config:
        namespace = 'tape_backup.drive'
        cli_namespace = 'tape_backup.drive'
        private = False

    @accepts()
    @returns(Dict('tape_drives', additional_attrs=True))
    async def query(self):
        """Detect and return information about all connected tape drives."""
        drives = []

        try:
            cp = subprocess.run(
                ['lsscsi', '--transport'],
                capture_output=True, text=True, timeout=10,
            )
            if cp.returncode == 0:
                drives = self._parse_lsscsi(cp.stdout)
        except FileNotFoundError:
            drives = await self._fallback_scan()
        except subprocess.TimeoutExpired:
            raise CallError('Timeout scanning for SCSI devices')

        return drives

    @private
    def _parse_lsscsi(self, output):
        """Parse lsscsi output to find tape and mediumx (changer) devices."""
        drives = []
        for line in output.strip().splitlines():
            parts = line.split()
            if len(parts) < 4:
                continue

            scsi_addr = parts[0].strip('[]')

            device_type = None
            dev_path = None
            vendor = ''
            model = ''
            revision = ''

            if 'tape' in line.lower():
                device_type = 'tape'
            elif 'mediumx' in line.lower() or 'medium' in line.lower():
                device_type = 'changer'
            else:
                continue

            dev_path_match = re.search(r'(/dev/\S+)', line)
            if dev_path_match:
                dev_path = dev_path_match.group(1)

            remaining = line.split(']', 1)[-1].strip() if ']' in line else line
            token_parts = remaining.split()
            if len(token_parts) >= 3:
                vendor = token_parts[0] if not token_parts[0].startswith('/dev') else ''
                model = token_parts[1] if len(token_parts) > 1 and not token_parts[1].startswith('/dev') else ''
                revision = token_parts[2] if len(token_parts) > 2 and not token_parts[2].startswith('/dev') else ''

            nst_device = None
            st_device = None
            sg_device = None

            if device_type == 'tape' and dev_path:
                if dev_path.startswith('/dev/st'):
                    st_device = dev_path
                    num = dev_path.replace('/dev/st', '')
                    nst_device = f'/dev/nst{num}'
                elif dev_path.startswith('/dev/nst'):
                    nst_device = dev_path
                    num = dev_path.replace('/dev/nst', '')
                    st_device = f'/dev/st{num}'

            if device_type == 'changer':
                sg_device = dev_path

            drive_info = {
                'scsi_address': scsi_addr,
                'type': device_type,
                'vendor': vendor.strip(),
                'model': model.strip(),
                'revision': revision.strip(),
                'device': dev_path or '',
                'nst_device': nst_device or '',
                'st_device': st_device or '',
                'sg_device': sg_device or '',
            }
            drives.append(drive_info)

        return drives

    @private
    async def _fallback_scan(self):
        """Scan /dev for tape devices when lsscsi is not available."""
        drives = []

        for st_path in sorted(glob.glob('/dev/st[0-9]*')):
            if 'nst' in st_path:
                continue
            num = st_path.replace('/dev/st', '')
            nst_path = f'/dev/nst{num}'

            drive_info = {
                'scsi_address': '',
                'type': 'tape',
                'vendor': '',
                'model': '',
                'revision': '',
                'device': st_path,
                'nst_device': nst_path if os.path.exists(nst_path) else '',
                'st_device': st_path,
                'sg_device': '',
            }

            try:
                cp = subprocess.run(
                    ['sg_inq', st_path],
                    capture_output=True, text=True, timeout=5,
                )
                if cp.returncode == 0:
                    for line in cp.stdout.splitlines():
                        if 'Vendor identification:' in line:
                            drive_info['vendor'] = line.split(':', 1)[1].strip()
                        elif 'Product identification:' in line:
                            drive_info['model'] = line.split(':', 1)[1].strip()
                        elif 'Product revision level:' in line:
                            drive_info['revision'] = line.split(':', 1)[1].strip()
            except (FileNotFoundError, subprocess.TimeoutExpired):
                pass

            drives.append(drive_info)

        for sg_path in sorted(glob.glob('/dev/sg[0-9]*')):
            try:
                cp = subprocess.run(
                    ['sg_inq', sg_path],
                    capture_output=True, text=True, timeout=5,
                )
                if cp.returncode == 0 and 'Medium changer' in cp.stdout:
                    vendor = ''
                    model = ''
                    for line in cp.stdout.splitlines():
                        if 'Vendor identification:' in line:
                            vendor = line.split(':', 1)[1].strip()
                        elif 'Product identification:' in line:
                            model = line.split(':', 1)[1].strip()

                    drives.append({
                        'scsi_address': '',
                        'type': 'changer',
                        'vendor': vendor,
                        'model': model,
                        'revision': '',
                        'device': sg_path,
                        'nst_device': '',
                        'st_device': '',
                        'sg_device': sg_path,
                    })
            except (FileNotFoundError, subprocess.TimeoutExpired):
                pass

        return drives

    @accepts(Str('device_path'))
    @returns(Dict('tape_status', additional_attrs=True))
    async def status(self, device_path):
        """Get current status of a tape drive."""
        if not device_path.startswith('/dev/'):
            raise CallError('Invalid device path')

        if not os.path.exists(device_path):
            raise CallError(f'Device {device_path} does not exist')

        result = {
            'device': device_path,
            'online': False,
            'ready': False,
            'tape_loaded': False,
            'write_protected': False,
            'block_size': 0,
            'file_number': -1,
            'block_number': -1,
            'density': '',
            'raw_status': '',
        }

        try:
            cp = subprocess.run(
                ['mt', '-f', device_path, 'status'],
                capture_output=True, text=True, timeout=30,
            )
            result['raw_status'] = cp.stdout

            if cp.returncode == 0:
                result['online'] = True
                output = cp.stdout

                if 'ONLINE' in output:
                    result['ready'] = True
                    result['tape_loaded'] = True

                if 'WR_PROT' in output:
                    result['write_protected'] = True

                bs_match = re.search(r'Tape block size (\d+)', output)
                if bs_match:
                    result['block_size'] = int(bs_match.group(1))

                fn_match = re.search(r'File number=(\d+)', output)
                if fn_match:
                    result['file_number'] = int(fn_match.group(1))

                bn_match = re.search(r'block number=(\d+)', output)
                if bn_match:
                    result['block_number'] = int(bn_match.group(1))

                dens_match = re.search(r'Density code (0x[0-9a-fA-F]+)', output)
                if dens_match:
                    result['density'] = dens_match.group(1)

        except subprocess.TimeoutExpired:
            result['raw_status'] = 'Timeout reading tape status'
        except FileNotFoundError:
            raise CallError('mt command not found. Ensure mt-st is installed.')

        return result

    @accepts(Str('device_path'))
    async def eject(self, device_path):
        """Eject/unload tape from drive."""
        if not device_path.startswith('/dev/'):
            raise CallError('Invalid device path')

        cp = subprocess.run(
            ['mt', '-f', device_path, 'offline'],
            capture_output=True, text=True, timeout=60,
        )
        if cp.returncode != 0:
            raise CallError(f'Failed to eject tape: {cp.stderr}')

        return True

    @accepts(Str('device_path'))
    async def rewind(self, device_path):
        """Rewind tape to beginning."""
        if not device_path.startswith('/dev/'):
            raise CallError('Invalid device path')

        cp = subprocess.run(
            ['mt', '-f', device_path, 'rewind'],
            capture_output=True, text=True, timeout=300,
        )
        if cp.returncode != 0:
            raise CallError(f'Failed to rewind tape: {cp.stderr}')

        return True

    @accepts(Dict(
        'drive_config',
        Str('nst_device', required=True),
        Str('media_type', default='LTO-8'),
        Int('max_block_size', default=1048576),
        Str('sg_device', default=''),
        Int('drive_index', default=0),
    ))
    async def configure(self, data):
        """Save drive configuration and regenerate Bareos storage daemon config."""
        config = await self.middleware.call('tape_backup.bareos.get_config')

        drive_configs = config.get('drives', [])

        existing = None
        for i, d in enumerate(drive_configs):
            if d.get('nst_device') == data['nst_device']:
                existing = i
                break

        if existing is not None:
            drive_configs[existing] = data
        else:
            drive_configs.append(data)

        config['drives'] = drive_configs
        config['media_type'] = data.get('media_type', config.get('media_type', 'LTO-8'))

        await self.middleware.call('tape_backup.bareos.save_config', config)
        await self.middleware.call('tape_backup.bareos.generate_config')

        return data
