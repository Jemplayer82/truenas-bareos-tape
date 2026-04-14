import {
  ChangeDetectionStrategy, Component, OnInit, inject, signal,
} from '@angular/core';
import { CommonModule } from '@angular/common';
import { Router } from '@angular/router';
import { MatButtonModule } from '@angular/material/button';
import { MatCardModule } from '@angular/material/card';
import { MatIconModule } from '@angular/material/icon';
import { MatMenuModule } from '@angular/material/menu';
import { MatProgressSpinnerModule } from '@angular/material/progress-spinner';
import { MatTableModule } from '@angular/material/table';
import { MatTooltipModule } from '@angular/material/tooltip';
import { TranslateModule } from '@ngx-translate/core';
import { marker as T } from '@biesbjerg/ngx-translate-extract-marker';

import { ApiService } from 'app/modules/websocket/api.service';

interface TapeJob {
  id: number;
  name: string;
  source_paths: string[];
  schedule: string;
  level: string;
  pool: string;
  enabled: boolean;
  compression: boolean;
  compression_algo: string;
  description: string;
}

@Component({
  selector: 'ix-tape-job-list',
  standalone: true,
  imports: [
    CommonModule,
    MatButtonModule,
    MatCardModule,
    MatIconModule,
    MatMenuModule,
    MatProgressSpinnerModule,
    MatTableModule,
    MatTooltipModule,
    TranslateModule,
  ],
  templateUrl: './tape-job-list.component.html',
  styleUrls: ['./tape-job-list.component.scss'],
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class TapeJobListComponent implements OnInit {
  private api = inject(ApiService);
  private router = inject(Router);

  jobs = signal<TapeJob[]>([]);
  loading = signal(true);
  runningJobId = signal<number | null>(null);

  displayedColumns = ['enabled', 'name', 'source_paths', 'level', 'pool', 'schedule', 'actions'];

  ngOnInit(): void {
    this.loadJobs();
  }

  async loadJobs(): Promise<void> {
    this.loading.set(true);
    try {
      const result = await this.api.call('tape_backup.job.query').toPromise();
      this.jobs.set(result as TapeJob[]);
    } catch (error) {
      console.error('Failed to load tape backup jobs:', error);
    } finally {
      this.loading.set(false);
    }
  }

  createJob(): void {
    this.router.navigate(['/data-protection/tape-backup/jobs/create']);
  }

  editJob(job: TapeJob): void {
    this.router.navigate(['/data-protection/tape-backup/jobs', job.id, 'edit']);
  }

  async runJob(job: TapeJob): Promise<void> {
    this.runningJobId.set(job.id);
    try {
      await this.api.job('tape_backup.job.run', [job.id]).toPromise();
    } catch (error) {
      console.error('Failed to run job:', error);
    } finally {
      this.runningJobId.set(null);
    }
  }

  async deleteJob(job: TapeJob): Promise<void> {
    try {
      await this.api.call('tape_backup.job.delete', [job.id]).toPromise();
      await this.loadJobs();
    } catch (error) {
      console.error('Failed to delete job:', error);
    }
  }

  async toggleEnabled(job: TapeJob): Promise<void> {
    try {
      await this.api.call('tape_backup.job.update', [job.id, { enabled: !job.enabled }]).toPromise();
      await this.loadJobs();
    } catch (error) {
      console.error('Failed to toggle job:', error);
    }
  }

  formatPaths(paths: string[]): string {
    if (!paths || paths.length === 0) return '-';
    if (paths.length === 1) return paths[0];
    return `${paths[0]} (+${paths.length - 1} more)`;
  }
}
