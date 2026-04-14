import {
  ChangeDetectionStrategy, Component, OnInit, inject, signal,
} from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormBuilder, ReactiveFormsModule, Validators } from '@angular/forms';
import { Router } from '@angular/router';
import { MatButtonModule } from '@angular/material/button';
import { MatCardModule } from '@angular/material/card';
import { MatCheckboxModule } from '@angular/material/checkbox';
import { MatFormFieldModule } from '@angular/material/form-field';
import { MatIconModule } from '@angular/material/icon';
import { MatInputModule } from '@angular/material/input';
import { MatListModule } from '@angular/material/list';
import { MatProgressSpinnerModule } from '@angular/material/progress-spinner';
import { MatSelectModule } from '@angular/material/select';
import { MatStepperModule } from '@angular/material/stepper';
import { TranslateModule } from '@ngx-translate/core';
import { marker as T } from '@biesbjerg/ngx-translate-extract-marker';

import { ApiService } from 'app/modules/websocket/api.service';

interface RecentJob {
  jobid: number;
  name: string;
  level: string;
  job_status: string;
  start_time: string;
  end_time: string;
  job_bytes: number;
  job_files: number;
}

@Component({
  selector: 'ix-tape-restore',
  standalone: true,
  imports: [
    CommonModule,
    ReactiveFormsModule,
    MatButtonModule,
    MatCardModule,
    MatCheckboxModule,
    MatFormFieldModule,
    MatIconModule,
    MatInputModule,
    MatListModule,
    MatProgressSpinnerModule,
    MatSelectModule,
    MatStepperModule,
    TranslateModule,
  ],
  templateUrl: './tape-restore.component.html',
  styleUrls: ['./tape-restore.component.scss'],
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class TapeRestoreComponent implements OnInit {
  private api = inject(ApiService);
  private fb = inject(FormBuilder);
  private router = inject(Router);

  recentJobs = signal<RecentJob[]>([]);
  loading = signal(true);
  restoring = signal(false);
  restoreComplete = signal(false);
  restoreResult = signal('');

  replaceOptions = [
    { value: 'never', label: T('Never (skip existing)') },
    { value: 'ifnewer', label: T('If newer') },
    { value: 'ifolder', label: T('If older') },
    { value: 'always', label: T('Always overwrite') },
  ];

  selectForm = this.fb.group({
    selectedJobId: [null as number | null, Validators.required],
  });

  filesForm = this.fb.group({
    file_list: [''],
    restore_all: [true],
  });

  destinationForm = this.fb.group({
    destination: ['/tmp/bareos-restores', Validators.required],
    replace: ['never'],
    client: ['bareos-fd'],
  });

  ngOnInit(): void {
    this.loadRecentJobs();
  }

  async loadRecentJobs(): Promise<void> {
    this.loading.set(true);
    try {
      const jobs = await this.api.call('tape_backup.inventory.recent_jobs', [50]).toPromise();
      const successfulJobs = (jobs as RecentJob[]).filter(j =>
        j.job_status === 'T' || j.job_status === 'W'
      );
      this.recentJobs.set(successfulJobs);
    } catch (error) {
      console.error('Failed to load recent jobs:', error);
    } finally {
      this.loading.set(false);
    }
  }

  get selectedJob(): RecentJob | null {
    const id = this.selectForm.get('selectedJobId')?.value;
    if (!id) return null;
    return this.recentJobs().find(j => j.jobid === id) || null;
  }

  formatBytes(bytes: number): string {
    if (bytes === 0) return '0 B';
    const k = 1024;
    const sizes = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
    const i = Math.floor(Math.log(bytes) / Math.log(k));
    return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + ' ' + sizes[i];
  }

  async startRestore(): Promise<void> {
    this.restoring.set(true);
    this.restoreComplete.set(false);

    const fileListRaw = this.filesForm.get('file_list')?.value || '';
    const restoreAll = this.filesForm.get('restore_all')?.value;

    const fileList = restoreAll
      ? []
      : fileListRaw.split('\n').map((f: string) => f.trim()).filter((f: string) => f.length > 0);

    const payload = {
      job_id: this.selectForm.get('selectedJobId')?.value,
      client: this.destinationForm.get('client')?.value || 'bareos-fd',
      file_list: fileList,
      destination: this.destinationForm.get('destination')?.value || '/tmp/bareos-restores',
      replace: this.destinationForm.get('replace')?.value || 'never',
    };

    try {
      await this.api.job('tape_backup.job.restore', [payload]).toPromise();
      this.restoreComplete.set(true);
      this.restoreResult.set(
        `Restore completed to ${payload.destination}`
      );
    } catch (error: any) {
      this.restoreResult.set(`Restore failed: ${error?.message || error}`);
      this.restoreComplete.set(true);
    } finally {
      this.restoring.set(false);
    }
  }

  goToDashboard(): void {
    this.router.navigate(['/data-protection/tape-backup']);
  }
}
