import {
  ChangeDetectionStrategy, Component, OnInit, inject, signal,
} from '@angular/core';
import { CommonModule } from '@angular/common';
import { Router } from '@angular/router';
import { MatButtonModule } from '@angular/material/button';
import { MatCardModule } from '@angular/material/card';
import { MatIconModule } from '@angular/material/icon';
import { TranslateModule } from '@ngx-translate/core';
import { marker as T } from '@biesbjerg/ngx-translate-extract-marker';

import { ApiService } from 'app/modules/websocket/api.service';

@Component({
  selector: 'ix-tape-backup-card',
  standalone: true,
  imports: [
    CommonModule,
    MatButtonModule,
    MatCardModule,
    MatIconModule,
    TranslateModule,
  ],
  templateUrl: './tape-backup-card.component.html',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class TapeBackupCardComponent implements OnInit {
  private api = inject(ApiService);
  private router = inject(Router);

  serviceRunning = signal(false);
  driveCount = signal(0);
  lastBackup = signal('');
  totalJobs = signal(0);
  loaded = signal(false);

  ngOnInit(): void {
    this.loadSummary();
  }

  async loadSummary(): Promise<void> {
    try {
      const [status, drives] = await Promise.all([
        this.api.call('tape_backup.bareos.status').toPromise() as Promise<any>,
        this.api.call('tape_backup.drive.query').toPromise() as Promise<any[]>,
      ]);

      this.serviceRunning.set(status?.director?.running || false);
      this.driveCount.set(drives?.filter((d: any) => d.type === 'tape').length || 0);

      if (status?.director?.running) {
        try {
          const jobs = await this.api.call('tape_backup.inventory.recent_jobs', [1]).toPromise() as any[];
          if (jobs?.length > 0) {
            this.lastBackup.set(jobs[0].end_time || jobs[0].start_time || '');
            this.totalJobs.set(jobs[0].jobid || 0);
          }
        } catch {
          // Director may not have jobs yet
        }
      }
    } catch {
      // Service not configured yet
    } finally {
      this.loaded.set(true);
    }
  }

  navigateTo(path: string): void {
    this.router.navigate(['/data-protection/tape-backup', path]);
  }

  openDashboard(): void {
    this.router.navigate(['/data-protection/tape-backup']);
  }
}
