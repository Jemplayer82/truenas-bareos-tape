import {
  ChangeDetectionStrategy, Component, OnInit, inject, signal,
} from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormBuilder, ReactiveFormsModule, Validators } from '@angular/forms';
import { ActivatedRoute, Router } from '@angular/router';
import { MatButtonModule } from '@angular/material/button';
import { MatCardModule } from '@angular/material/card';
import { MatCheckboxModule } from '@angular/material/checkbox';
import { MatFormFieldModule } from '@angular/material/form-field';
import { MatIconModule } from '@angular/material/icon';
import { MatInputModule } from '@angular/material/input';
import { MatProgressSpinnerModule } from '@angular/material/progress-spinner';
import { MatSelectModule } from '@angular/material/select';
import { TranslateModule } from '@ngx-translate/core';
import { marker as T } from '@biesbjerg/ngx-translate-extract-marker';

import { ApiService } from 'app/modules/websocket/api.service';

@Component({
  selector: 'ix-tape-job-form',
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
    MatProgressSpinnerModule,
    MatSelectModule,
    TranslateModule,
  ],
  templateUrl: './tape-job-form.component.html',
  styleUrls: ['./tape-job-form.component.scss'],
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class TapeJobFormComponent implements OnInit {
  private fb = inject(FormBuilder);
  private api = inject(ApiService);
  private router = inject(Router);
  private route = inject(ActivatedRoute);

  isEdit = signal(false);
  editId = signal<number | null>(null);
  loading = signal(false);
  saving = signal(false);

  levelOptions = [
    { value: 'Full', label: T('Full') },
    { value: 'Incremental', label: T('Incremental') },
    { value: 'Differential', label: T('Differential') },
  ];

  poolOptions = [
    { value: 'Daily', label: T('Daily') },
    { value: 'Weekly', label: T('Weekly') },
    { value: 'Monthly', label: T('Monthly') },
    { value: 'Scratch', label: T('Scratch') },
  ];

  compressionOptions = [
    { value: 'LZ4', label: 'LZ4 (Fast)' },
    { value: 'GZIP', label: 'GZIP (Good compression)' },
    { value: 'LZO', label: 'LZO (Very fast)' },
    { value: 'LZFAST', label: 'LZFAST (Fastest)' },
    { value: 'None', label: T('None') },
  ];

  form = this.fb.group({
    name: ['', [Validators.required, Validators.maxLength(200)]],
    description: [''],
    source_paths: ['', Validators.required],
    exclude_patterns: ['*.tmp, *.swp, .Trash*'],
    schedule: [''],
    level: ['Incremental'],
    pool: ['Daily'],
    full_pool: ['Monthly'],
    differential_pool: ['Weekly'],
    incremental_pool: ['Daily'],
    compression: [true],
    compression_algo: ['LZ4'],
    signature: [true],
    priority: [10, [Validators.min(1), Validators.max(100)]],
    max_concurrent_jobs: [1, [Validators.min(1), Validators.max(10)]],
    enabled: [true],
    pre_script: [''],
    post_script: [''],
  });

  ngOnInit(): void {
    const id = this.route.snapshot.params['id'];
    if (id) {
      this.isEdit.set(true);
      this.editId.set(Number(id));
      this.loadJob(Number(id));
    }
  }

  async loadJob(id: number): Promise<void> {
    this.loading.set(true);
    try {
      const jobs = await this.api.call('tape_backup.job.query', [[['id', '=', id]]]).toPromise() as any[];
      if (jobs && jobs.length > 0) {
        const job = jobs[0];
        this.form.patchValue({
          name: job.name,
          description: job.description || '',
          source_paths: (job.source_paths || []).join('\n'),
          exclude_patterns: (job.exclude_patterns || []).join(', '),
          schedule: job.schedule || '',
          level: job.level,
          pool: job.pool,
          full_pool: job.full_pool,
          differential_pool: job.differential_pool,
          incremental_pool: job.incremental_pool,
          compression: job.compression,
          compression_algo: job.compression_algo,
          signature: job.signature,
          priority: job.priority,
          max_concurrent_jobs: job.max_concurrent_jobs,
          enabled: job.enabled,
          pre_script: job.pre_script || '',
          post_script: job.post_script || '',
        });
      }
    } catch (error) {
      console.error('Failed to load job:', error);
    } finally {
      this.loading.set(false);
    }
  }

  async onSubmit(): Promise<void> {
    if (this.form.invalid) return;

    this.saving.set(true);
    const formValue = this.form.value;

    const payload: any = {
      ...formValue,
      source_paths: (formValue.source_paths || '')
        .split('\n')
        .map((p: string) => p.trim())
        .filter((p: string) => p.length > 0),
      exclude_patterns: (formValue.exclude_patterns || '')
        .split(',')
        .map((p: string) => p.trim())
        .filter((p: string) => p.length > 0),
    };

    try {
      if (this.isEdit()) {
        await this.api.call('tape_backup.job.update', [this.editId(), payload]).toPromise();
      } else {
        await this.api.call('tape_backup.job.create', [payload]).toPromise();
      }
      this.router.navigate(['/data-protection/tape-backup/jobs']);
    } catch (error) {
      console.error('Failed to save job:', error);
    } finally {
      this.saving.set(false);
    }
  }

  onCancel(): void {
    this.router.navigate(['/data-protection/tape-backup/jobs']);
  }
}
