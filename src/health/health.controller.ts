import {
  Controller,
  Get,
  Header,
  Inject,
  ServiceUnavailableException,
} from '@nestjs/common';
import { Public } from '../auth/access.js';
import { PrismaService } from '../database/prisma.service.js';

@Controller('health')
export class HealthController {
  constructor(
    @Inject(PrismaService)
    private readonly database: Pick<PrismaService, '$queryRaw'>,
  ) {}

  @Public()
  @Get()
  @Header('Cache-Control', 'no-store')
  async check() {
    try {
      await this.database.$queryRaw`SELECT 1`;
      return { status: 'ok', database: 'up' };
    } catch {
      throw new ServiceUnavailableException({
        status: 'error',
        database: 'unavailable',
      });
    }
  }
}
