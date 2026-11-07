import { Module } from '@nestjs/common';
import { PrismaService } from './prisma.service.js';
import { TenantDatabase } from './tenant-database.js';

@Module({
  providers: [PrismaService, TenantDatabase],
  exports: [PrismaService, TenantDatabase],
})
export class DatabaseModule {}
