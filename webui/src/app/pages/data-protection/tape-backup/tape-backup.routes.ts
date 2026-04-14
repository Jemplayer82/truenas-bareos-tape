import { Routes } from '@angular/router';
import { marker as T } from '@biesbjerg/ngx-translate-extract-marker';

export const tapeBackupRoutes: Routes = [
  {
    path: '',
    loadComponent: () => import('./tape-backup-dashboard/tape-backup-dashboard.component')
      .then(m => m.TapeBackupDashboardComponent),
    data: { title: T('Tape Backup'), breadcrumb: T('Tape Backup') },
  },
  {
    path: 'jobs',
    loadComponent: () => import('./tape-job-list/tape-job-list.component')
      .then(m => m.TapeJobListComponent),
    data: { title: T('Tape Backup Jobs'), breadcrumb: T('Jobs') },
  },
  {
    path: 'jobs/create',
    loadComponent: () => import('./tape-job-form/tape-job-form.component')
      .then(m => m.TapeJobFormComponent),
    data: { title: T('Create Tape Backup Job'), breadcrumb: T('Create') },
  },
  {
    path: 'jobs/:id/edit',
    loadComponent: () => import('./tape-job-form/tape-job-form.component')
      .then(m => m.TapeJobFormComponent),
    data: { title: T('Edit Tape Backup Job'), breadcrumb: T('Edit') },
  },
  {
    path: 'drives',
    loadComponent: () => import('./tape-drive-list/tape-drive-list.component')
      .then(m => m.TapeDriveListComponent),
    data: { title: T('Tape Drives'), breadcrumb: T('Drives') },
  },
  {
    path: 'inventory',
    loadComponent: () => import('./tape-inventory/tape-inventory.component')
      .then(m => m.TapeInventoryComponent),
    data: { title: T('Tape Inventory'), breadcrumb: T('Inventory') },
  },
  {
    path: 'restore',
    loadComponent: () => import('./tape-restore/tape-restore.component')
      .then(m => m.TapeRestoreComponent),
    data: { title: T('Restore from Tape'), breadcrumb: T('Restore') },
  },
];
