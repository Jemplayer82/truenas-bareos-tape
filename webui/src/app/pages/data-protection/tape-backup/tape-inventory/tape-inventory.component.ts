import {
  ChangeDetectionStrategy, Component, OnInit, inject, signal,
} from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormBuilder, ReactiveFormsModule, Validators } from '@angular/forms';
import { MatButtonModule } from '@angular/material/button';
import { MatCardModule } from '@angular/material/card';
import { MatFormFieldModule } from '@angular/material/form-field';
import { MatIconModule } from '@angular/material/icon';
import { MatInputModule } from '@angular/material/input';
import { MatMenuModule } from '@angular/material/menu';
import { MatProgressSpinnerModule } from '@angular/material/progress-spinner';
import { MatSelectModule } from '@angular/material/select';
import { MatTableModule } from '@angular/material/table';
import { MatTooltipModule } from '@angular/material/tooltip';
import { TranslateModule } from '@ngx-translate/core';
import { marker as T } from '@biesbjerg/ngx-translate-extract-marker';

import { ApiService } from 'app/modules/websocket/api.service';

interface TapeVolume {
  volume_name: string;
  pool: string;
  media_type: string;
  volume_status: string;
  volume_bytes: number;
  volume_files: number;
  volume_jobs: number;
  first_written: string;
  last_written: string;
  recycle: boolean;
  slot: number;
  in_changer: boolean;
}

interface PoolInfo {
  pool_id: number;
  name: string;
  num_volumes: number;
  total_bytes: number;
  total_files: number;
  volume_retention: string;
  recycle: boolean;
  auto_prune: boolean;
}

@Component({
  selector: 'ix-tape-inventory',
  standalone: true,
  imports: [
    CommonModule,
    ReactiveFormsModule,
    MatButtonModule,
    MatCardModule,
    MatFormFieldModule,
    MatIconModule,
    MatInputModule,
    MatMenuModule,
    MatProgressSpinnerModule,
    MatSelectModule,
    MatTableModule,
    MatTooltipModule,
    TranslateModule,
  ],
  templateUrl: './tape-inventory.component.html',
  styleUrls: ['./tape-inventory.component.scss'],
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class TapeInventoryComponent implements OnInit {
  private api = inject(ApiService);
  private fb = inject(FormBuilder);

  volumes = signal<TapeVolume[]>([]);
  pools = signal<PoolInfo[]>([]);
  loading = signal(true);
  showLabelForm = signal(false);
  labeling = signal(false);

  volumeColumns = [
    'volume_name', 'pool', 'volume_status', 'volume_bytes',
    'volume_jobs', 'last_written', 'actions',
  ];

  labelForm = this.fb.group({
    volume_name: ['', [Validators.required, Validators.maxLength(120)]],
    pool: ['Scratch', Validators.required],
    storage: ['TapeStorage'],
    slot: [0],
  });

  ngOnInit(): void {
    this.loadInventory();
  }

  async loadInventory(): Promise<void> {
    this.loading.set(true);
    try {
      const [volumes, pools] = await Promise.all([
        this.api.call('tape_backup.inventory.volumes').toPromise(),
        this.api.call('tape_backup.inventory.pools').toPromise(),
      ]);
      this.volumes.set(volumes as TapeVolume[]);
      this.pools.set(pools as PoolInfo[]);
    } catch (error) {
      console.error('Failed to load inventory:', error);
    } finally {
      this.loading.set(false);
    }
  }

  openLabelForm(): void {
    this.showLabelForm.set(true);
    this.labelForm.reset({ volume_name: '', pool: 'Scratch', storage: 'TapeStorage', slot: 0 });
  }

  closeLabelForm(): void {
    this.showLabelForm.set(false);
  }

  async labelTape(): Promise<void> {
    if (this.labelForm.invalid) return;
    this.labeling.set(true);
    try {
      await this.api.job('tape_backup.inventory.label', [this.labelForm.value]).toPromise();
      this.showLabelForm.set(false);
      await this.loadInventory();
    } catch (error) {
      console.error('Failed to label tape:', error);
    } finally {
      this.labeling.set(false);
    }
  }

  async purgeVolume(volume: TapeVolume): Promise<void> {
    try {
      await this.api.call('tape_backup.inventory.purge', [volume.volume_name]).toPromise();
      await this.loadInventory();
    } catch (error) {
      console.error('Failed to purge volume:', error);
    }
  }

  async moveToPool(volume: TapeVolume, newPool: string): Promise<void> {
    try {
      await this.api.call('tape_backup.inventory.move_to_pool', [{
        volume_name: volume.volume_name,
        new_pool: newPool,
      }]).toPromise();
      await this.loadInventory();
    } catch (error) {
      console.error('Failed to move volume:', error);
    }
  }

  formatBytes(bytes: number): string {
    if (bytes === 0) return '0 B';
    const k = 1024;
    const sizes = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
    const i = Math.floor(Math.log(bytes) / Math.log(k));
    return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + ' ' + sizes[i];
  }

  getStatusClass(status: string): string {
    switch (status?.toLowerCase()) {
      case 'append': return 'status-append';
      case 'full': return 'status-full';
      case 'used': return 'status-used';
      case 'recycle': return 'status-recycle';
      case 'purged': return 'status-purged';
      case 'error': return 'status-error';
      default: return '';
    }
  }

  get poolNames(): string[] {
    return this.pools().map(p => p.name);
  }
}
