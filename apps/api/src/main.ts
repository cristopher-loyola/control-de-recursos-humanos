import { NestFactory } from '@nestjs/core';
import { ConfigService } from '@nestjs/config';
import { AppModule } from './app.module.js';

async function bootstrap() {
  const app = await NestFactory.create(AppModule);
  const config = app.get(ConfigService);
  app.enableShutdownHooks();
  app.enableCors({ origin: config.getOrThrow<string>('WEB_ORIGIN') });
  await app.listen(config.getOrThrow<number>('API_PORT'));
}
await bootstrap();
