import {
  ChangeDetectionStrategy, Component, OnInit, inject, signal,
} from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormBuilder, ReactiveFormsModule, Validators } from '@angular/forms';
import { MatButtonModule } from '@angular/material/button';
import { MatCardModule } from '@angular/material/card';
import { MatDialogModule, MatDialog } from '@angular/material/dialog';
import { MatFormFieldModule } from '@angular/material/form-field';
import { MatIconModule } from '@angular/material/icon';
import { MatInputModule } from '@angular/material/input';
import { MatProgressSpinnerModule } from '@angular/material/progress-spinner';
import { MatSelectModule } from '@angular/material/select';
import { MatTableModule } from '@angular/material/table';
import { MatTooltipModule } from '@angular/material/tooltip';
import { TranslateModule } from '@ngx-translate/core';
import { marker as T } from '@biesbjerg/ngx-translate-extract-marker';

import { ApiService } from 'app/modules/websocket/api.service';

interface TapeDrive {
  scsi_address: string;
  type: string;
  vendor: string;
  model: string;
  revision: string;
  device: string;
  nst_device: string;
  st_device: string;
  sg_device: string;
}

interface DriveStatus {
  device: string;
  online: boolean;
  ready: boolean;
  tape_loaded: boolean;
  write_protected: boolean;
  block_size: number;
  file_number: number;
  block_number: number;
  density: string;
  raw_status: string;
}

@Component({
  selector: 'ix-tape-drive-list',
  standalone: true,
  imports: [
    CommonModule,
    ReactiveFormsModule,
    MatButtonModule,
    MatCardModule,
    MatDialogModule,
    MatFormFieldModule,
    MatIconModule,
    MatInputModule,
    MatProgressSpinnerModule,
    MatSelectModule,
    MatTableModule,
    MatTooltipModule,
    TranslateModule,
  ],
  templateUrl: './tape-drive-list.component.html',
  styleUrls: ['./tape-drive-list.component.scss'],
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class TapeDriveListComponent implements OnInit {
  private api = inject(ApiService);
  private fb = inject(FormBuilder);

  drives = signal<TapeDrive[]>([]);
  loading = signal(true);
  selectedDrive = signal<TapeDrive | null>(null);
  driveStatus = signal<DriveStatus | null>(null);
  statusLoading = signal(false);
  configuring = signal(false);
  actionInProgress = signal<string | null>(null);

  driveColumns = ['type', 'vendor', 'model', 'device', 'actions'];

  mediaTypeOptions = [
    { value: 'LTO-5', label: 'LTO-5 (1.5 TB native)' },
    { value: 'LTO-6', label: 'LTO-6 (2.5 TB native)' },
    { value: 'LTO-7', label: 'LTO-7 (6 TB native)' },
    { value: 'LTO-8', label: 'LTO-8 (12 TB native)' },
    { value: 'LTO-9', label: 'LTO-9 (18 TB native)' },
  ];

  configForm = this.fb.group({
    nst_device: ['', Validators.required],
    media_type: ['LTO-8'],
    max_block_size: [1048576, [Validators.min(512), Validators.max(4194304)]],
    sg_device: [''],
    drive_index: [0],
  });

  ngOnInit(): void {
    this.loadDrives();
  }

  async loadDrives(): Promise<void> {
    this.loading.set(true);
    try {
      const result = await this.api.call('tape_backup.drive.query').toPromise();
      this.drives.set(result as TapeDrive[]);
    } catch (error) {
      console.error('Failed to load drives:', error);
    } finally {
      this.loading.set(false);
    }
  }

  async viewStatus(drive: TapeDrive): Promise<void> {
    this.selectedDrive.set(drive);
    this.statusLoading.set(true);
    this.driveStatus.set(null);

    const devicePath = drive.nst_device || drive.st_device || drive.device;
    try {
      const result = await this.api.call('tape_backup.drive.status', [devicePath]).toPromise();
      this.driveStatus.set(result as DriveStatus);
    } catch (error) {
      console.error('Failed to get drive status:', error);
    } finally {
      this.statusLoading.set(false);
    }
  }

  openConfigure(drive: TapeDrive): void {
    this.configuring.set(true);
    this.configForm.patchValue({
      nst_device: drive.nst_device || drive.device,
      sg_device: drive.sg_device || '',
    });
  }

  async saveConfigure(): Promise<void> {
    if (this.configForm.invalid) return;
    try {
      await this.api.call('tape_backup.drive.configure', [this.configForm.value]).toPromise();
      this.configuring.set(false);
    } catch (error) {
      console.error('Failed to configure drive:', error);
    }
  }

  cancelConfigure(): void {
    this.configuring.set(false);
  }

  async ejectTape(drive: TapeDrive): Promise<void> {
    const devicePath = drive.nst_device || drive.device;
    this.actionInProgress.set(devicePath + '-eject');
    try {
      await this.api.call('tape_backup.drive.eject', [devicePath]).toPromise();
      await this.viewStatus(drive);
    } catch (error) {
      console.error('Failed to eject tape:', error);
    } finally {
      this.actionInProgress.set(null);
    }
  }

  async rewindTape(drive: TapeDrive): Promise<void> {
    const devicePath = drive.nst_device || drive.device;
    this.actionInProgress.set(devicePath + '-rewind');
    try {
      await this.api.call('tape_backup.drive.rewind', [devicePath]).toPromise();
      await this.viewStatus(drive);
    } catch (error) {
      console.error('Failed to rewind tape:', error);
    } finally {
      this.actionInProgress.set(null);
    }
  }

  closeStatus(): void {
    this.selectedDrive.set(null);
    this.driveStatus.set(null);
  }
}
