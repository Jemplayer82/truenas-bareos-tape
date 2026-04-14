import {
  ChangeDetectionStrategy, Component, OnInit, inject, signal,
} from '@angular/core';
import { CommonModule } from '@angular/common';
import { Router, RouterLink } from '@angular/router';
import { MatButtonModule } from '@angular/material/button';
import { MatCardModule } from '@angular/material/card';
import { MatIconModule } from '@angular/material/icon';
import { MatProgressSpinnerModule } from '@angular/material/progress-spinner';
import { MatTableModule } from '@angular/material/table';
import { MatTooltipModule } from '@angular/material/tooltip';
import { TranslateModule } from '@ngx-translate/core';
import { marker as T } from '@biesbjerg/ngx-translate-extract-marker';

import { ApiService } from 'app/modules/websocket/api.service';

interface BareosStatus {
  director: { service: string; state: string; running: boolean };
  storage: { service: string; state: string; running: boolean };
  filedaemon: { service: string; state: string; running: boolean };
}

interface RecentJob {
  jobid: number;
  name: string;
  type: string;
  level: string;
  job_status: string;
  start_time: string;
  end_time: string;
  job_bytes: number;
  job_files: number;
}

interface TapeDrive {
  type: string;
  vendor: string;
  model: string;
  device: string;
  nst_device: string;
}

interface PoolInfo {
  name: string;
  num_volumes: number;
  total_bytes: number;
  total_files: number;
}

@Component({
  selector: 'ix-tape-backup-dashboard',
  standalone: true,
  imports: [
    CommonModule,
    RouterLink,
    MatButtonModule,
    MatCardModule,
    MatIconModule,
    MatProgressSpinnerModule,
    MatTableModule,
    MatTooltipModule,
    TranslateModule,
  ],
  templateUrl: './tape-backup-dashboard.component.html',
  styleUrls: ['./tape-backup-dashboard.component.scss'],
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class TapeBackupDashboardComponent implements OnInit {
  private api = inject(ApiService);
  private router = inject(Router);

  bareosStatus = signal<BareosStatus | null>(null);
  recentJobs = signal<RecentJob[]>([]);
  tapeDrives = signal<TapeDrive[]>([]);
  pools = signal<PoolInfo[]>([]);
  loading = signal(true);
  serviceToggling = signal(false);

  jobColumns = ['jobid', 'name', 'level', 'job_status', 'start_time', 'job_bytes', 'job_files'];

  ngOnInit(): void {
    this.loadDashboard();
  }

  async loadDashboard(): Promise<void> {
    this.loading.set(true);

    try {
      const [status, drives] = await Promise.all([
        this.api.call('tape_backup.bareos.status').toPromise(),
        this.api.call('tape_backup.drive.query').toPromise(),
      ]);

      this.bareosStatus.set(status as BareosStatus);
      this.tapeDrives.set(drives as TapeDrive[]);

      if ((status as BareosStatus)?.director?.running) {
        const [jobs, poolData] = await Promise.all([
          this.api.call('tape_backup.inventory.recent_jobs', [10]).toPromise(),
          this.api.call('tape_backup.inventory.pools').toPromise(),
        ]);
        this.recentJobs.set(jobs as RecentJob[]);
        this.pools.set(poolData as PoolInfo[]);
      }
    } catch (error) {
      console.error('Failed to load tape backup dashboard:', error);
    } finally {
      this.loading.set(false);
    }
  }

  get allServicesRunning(): boolean {
    const status = this.bareosStatus();
    if (!status) return false;
    return status.director.running && status.storage.running && status.filedaemon.running;
  }

  async toggleServices(): Promise<void> {
    this.serviceToggling.set(true);
    try {
      if (this.allServicesRunning) {
        await this.api.call('tape_backup.bareos.stop').toPromise();
      } else {
        await this.api.call('tape_backup.bareos.start').toPromise();
      }
      await this.loadDashboard();
    } catch (error) {
      console.error('Failed to toggle Bareos services:', error);
    } finally {
      this.serviceToggling.set(false);
    }
  }

  async runSetup(): Promise<void> {
    this.loading.set(true);
    try {
      await this.api.job('tape_backup.bareos.setup').toPromise();
      await this.loadDashboard();
    } catch (error) {
      console.error('Bareos setup failed:', error);
    } finally {
      this.loading.set(false);
    }
  }

  navigateTo(path: string): void {
    this.router.navigate(['/data-protection/tape-backup', path]);
  }

  formatBytes(bytes: number): string {
    if (bytes === 0) return '0 B';
    const k = 1024;
    const sizes = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
    const i = Math.floor(Math.log(bytes) / Math.log(k));
    return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + ' ' + sizes[i];
  }

  getStatusIcon(status: string): string {
    switch (status) {
      case 'T': return 'check_circle';
      case 'R': return 'play_circle';
      case 'E': case 'e': case 'f': return 'error';
      case 'A': return 'cancel';
      case 'W': return 'warning';
      default: return 'help';
    }
  }

  getStatusClass(status: string): string {
    switch (status) {
      case 'T': return 'status-success';
      case 'R': return 'status-running';
      case 'E': case 'e': case 'f': return 'status-error';
      case 'A': return 'status-cancelled';
      case 'W': return 'status-warning';
      default: return 'status-unknown';
    }
  }
}
