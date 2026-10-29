import { HttpErrorResponse } from '@angular/common/http';
import { Component, DestroyRef, inject, OnInit, signal } from '@angular/core';
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';
import { RouterOutlet } from '@angular/router';
import { HealthService } from './core/health.service';

type ConnectionState = 'idle' | 'checking' | 'available' | 'database-unavailable' | 'unavailable';

@Component({
  imports: [RouterOutlet],
  selector: 'app-root',
  styleUrl: './app.scss',
  templateUrl: './app.html',
})
export class App implements OnInit {
  private readonly health = inject(HealthService);
  private readonly destroyRef = inject(DestroyRef);
  protected readonly connectionState = signal<ConnectionState>('idle');

  ngOnInit(): void {
    this.checkConnection();
  }

  protected checkConnection(): void {
    if (this.connectionState() === 'checking') {
      return;
    }

    this.connectionState.set('checking');
    this.health.check().pipe(takeUntilDestroyed(this.destroyRef)).subscribe({
      next: () => this.connectionState.set('available'),
      error: (error: unknown) => {
        const databaseUnavailable =
          error instanceof HttpErrorResponse &&
          error.status === 503 &&
          error.error?.database === 'unavailable';
        this.connectionState.set(databaseUnavailable ? 'database-unavailable' : 'unavailable');
      },
    });
  }
}
