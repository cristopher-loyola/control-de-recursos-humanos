import {
  BadRequestException,
  Body,
  ConflictException,
  Controller,
  Delete,
  Get,
  HttpCode,
  Inject,
  NotFoundException,
  Param,
  Post,
  Put,
} from '@nestjs/common';
import { recordAudit } from '../audit/record-audit.js';
import { CurrentAuth, RequirePermissions } from '../auth/access.js';
import type { AuthContext } from '../auth/access.js';
import { readBody, text, uuid } from '../common/input.js';
import { TenantDatabase } from '../database/tenant-database.js';
import type { TenantTransaction } from '../database/tenant-database.js';
import { BiometricBox } from './biometric-box.js';
import { FACE_MODEL_ID, FACE_THRESHOLD, readSamples, score } from './face.js';
import { hashPin, pinProblem } from './pin.js';

/** Versión del aviso de privacidad que firma el empleado para el servidor. */
export const CONSENT_POLICY_VERSION = 'servidor-v1';

async function requireEmployee(tx: TenantTransaction, id: string) {
  const employee = await tx.employee.findUnique({
    where: { id },
    select: { id: true, employeeNumber: true, employmentStatus: true },
  });
  if (!employee) throw new NotFoundException('El empleado no existe.');
  return employee;
}

@Controller('employees/:id')
export class BiometricsController {
  constructor(
    @Inject(TenantDatabase) private readonly db: TenantDatabase,
    @Inject(BiometricBox) private readonly box: BiometricBox,
  ) {}

  @RequirePermissions('employees.read')
  @Get('consents')
  consents(@CurrentAuth() auth: AuthContext, @Param('id') rawId: string) {
    const id = uuid(rawId, 'El empleado');
    return this.db.run(auth.companyId, async (tx) => {
      await requireEmployee(tx, id);
      return (
        await tx.biometricConsent.findMany({
          where: { employeeId: id },
          orderBy: { grantedAt: 'desc' },
          select: {
            id: true,
            policyVersion: true,
            signedDocumentObjectKey: true,
            grantedAt: true,
            revokedAt: true,
            recordedBy: { select: { email: true } },
          },
        })
      ).map(({ signedDocumentObjectKey, ...consent }) => ({
        ...consent,
        documentReference: signedDocumentObjectKey,
      }));
    });
  }

  /**
   * `recorded`: folio del consentimiento firmado (el original se guarda aparte).
   * `revoked`: retira el consentimiento y la plantilla facial al instante.
   */
  @RequirePermissions('biometrics.manage')
  @Post('consents')
  @HttpCode(200)
  recordConsent(
    @CurrentAuth() auth: AuthContext,
    @Param('id') rawId: string,
    @Body() raw: unknown,
  ) {
    const id = uuid(rawId, 'El empleado');
    const body = readBody(raw);
    const kind = body.kind;
    if (kind !== 'recorded' && kind !== 'revoked') {
      throw new BadRequestException('Indica si se registra o se revoca.');
    }
    const reference = text(
      body,
      'documentReference',
      'El folio del documento',
      120,
    );
    if (reference.length < 5) {
      throw new BadRequestException(
        'El folio debe tener al menos 5 caracteres.',
      );
    }
    return this.db.run(auth.companyId, async (tx) => {
      await requireEmployee(tx, id);
      const now = new Date();
      const active = await tx.biometricConsent.findFirst({
        where: { employeeId: id, revokedAt: null },
      });
      if (kind === 'recorded') {
        if (active) {
          throw new ConflictException(
            'El empleado ya tiene un consentimiento vigente.',
          );
        }
        const consent = await tx.biometricConsent.create({
          data: {
            companyId: auth.companyId,
            employeeId: id,
            recordedByAccountId: auth.accountId,
            policyVersion: CONSENT_POLICY_VERSION,
            signedDocumentObjectKey: reference,
            grantedAt: now,
          },
        });
        await recordAudit(tx, {
          companyId: auth.companyId,
          actorAccountId: auth.accountId,
          action: 'consent.recorded',
          entityType: 'employee',
          entityId: id,
          details: { consentId: consent.id, documentReference: reference },
        });
        return { id: consent.id, documentReference: reference, grantedAt: now };
      }
      if (!active) {
        throw new ConflictException(
          'El empleado no tiene un consentimiento vigente.',
        );
      }
      await tx.biometricConsent.update({
        where: { id: active.id },
        data: { revokedAt: now },
      });
      const removed = await tx.faceTemplate.updateMany({
        where: { employeeId: id, revokedAt: null },
        data: { revokedAt: now },
      });
      await recordAudit(tx, {
        companyId: auth.companyId,
        actorAccountId: auth.accountId,
        action: 'consent.revoked',
        entityType: 'employee',
        entityId: id,
        details: {
          consentId: active.id,
          documentReference: reference,
          faceTemplatesRevoked: removed.count,
        },
      });
      return { id: active.id, revokedAt: now };
    });
  }

  /** Registra o reemplaza el rostro con las tomas hechas en la tablet. */
  @RequirePermissions('biometrics.manage')
  @Post('face')
  enrollFace(
    @CurrentAuth() auth: AuthContext,
    @Param('id') rawId: string,
    @Body() raw: unknown,
  ) {
    const id = uuid(rawId, 'El empleado');
    const body = readBody(raw);
    if (body.modelId !== FACE_MODEL_ID) {
      throw new BadRequestException(
        'La tablet usa otro modelo facial. Actualiza la aplicación.',
      );
    }
    const samples = readSamples(body.samples);
    return this.db.run(auth.companyId, async (tx) => {
      const employee = await requireEmployee(tx, id);
      if (employee.employmentStatus !== 'ACTIVE') {
        throw new BadRequestException('El empleado está dado de baja.');
      }
      const consent = await tx.biometricConsent.findFirst({
        where: { employeeId: id, revokedAt: null },
      });
      if (!consent) {
        throw new BadRequestException(
          'Registra el consentimiento firmado antes de guardar el rostro.',
        );
      }
      // El mismo rostro no puede quedar con dos números de empleado.
      const others = await tx.faceTemplate.findMany({
        where: {
          revokedAt: null,
          employeeId: { not: id },
          modelId: FACE_MODEL_ID,
        },
        select: { id: true, employeeId: true, encryptedSamples: true },
      });
      for (const other of others) {
        const enrolled = this.box.openFace(
          auth.companyId,
          other.employeeId,
          other.id,
          other.encryptedSamples,
        );
        if (score(samples, enrolled) >= FACE_THRESHOLD) {
          throw new ConflictException(
            'Este rostro se parece a uno ya registrado. Revisa el empleado antes de continuar.',
          );
        }
      }
      const now = new Date();
      await tx.faceTemplate.updateMany({
        where: { employeeId: id, revokedAt: null },
        data: { revokedAt: now },
      });
      const templateId = crypto.randomUUID();
      await tx.faceTemplate.create({
        data: {
          id: templateId,
          companyId: auth.companyId,
          employeeId: id,
          consentId: consent.id,
          modelId: FACE_MODEL_ID,
          sampleCount: samples.length,
          encryptedSamples: this.box.sealFace(
            auth.companyId,
            id,
            templateId,
            samples,
          ),
          createdByAccountId: auth.accountId,
        },
      });
      await recordAudit(tx, {
        companyId: auth.companyId,
        actorAccountId: auth.accountId,
        action: 'face.enrolled',
        entityType: 'employee',
        entityId: id,
        details: { faceTemplateId: templateId, consentId: consent.id },
      });
      return { id: templateId, modelId: FACE_MODEL_ID, consentId: consent.id };
    });
  }

  /** Asigna o cambia el PIN de respaldo. El PIN en claro nunca se guarda. */
  @RequirePermissions('biometrics.manage')
  @Put('pin')
  @HttpCode(204)
  async setPin(
    @CurrentAuth() auth: AuthContext,
    @Param('id') rawId: string,
    @Body() raw: unknown,
  ) {
    const id = uuid(rawId, 'El empleado');
    const pin = readBody(raw).pin;
    if (typeof pin !== 'string') {
      throw new BadRequestException('Escribe el PIN.');
    }
    const problem = pinProblem(pin);
    if (problem) throw new BadRequestException(problem);
    const { salt, hash, iterations } = await hashPin(pin);
    await this.db.run(auth.companyId, async (tx) => {
      await requireEmployee(tx, id);
      const data = {
        salt: new Uint8Array(salt),
        pinHash: new Uint8Array(hash),
        iterations,
      };
      await tx.employeePin.upsert({
        where: {
          companyId_employeeId: { companyId: auth.companyId, employeeId: id },
        },
        create: { companyId: auth.companyId, employeeId: id, ...data },
        update: data,
      });
      await recordAudit(tx, {
        companyId: auth.companyId,
        actorAccountId: auth.accountId,
        action: 'pin.assigned',
        entityType: 'employee',
        entityId: id,
      });
    });
  }

  @RequirePermissions('biometrics.manage')
  @Delete('pin')
  @HttpCode(204)
  async removePin(
    @CurrentAuth() auth: AuthContext,
    @Param('id') rawId: string,
  ) {
    const id = uuid(rawId, 'El empleado');
    await this.db.run(auth.companyId, async (tx) => {
      await requireEmployee(tx, id);
      const removed = await tx.employeePin.deleteMany({
        where: { employeeId: id },
      });
      if (removed.count > 0) {
        await recordAudit(tx, {
          companyId: auth.companyId,
          actorAccountId: auth.accountId,
          action: 'pin.removed',
          entityType: 'employee',
          entityId: id,
        });
      }
    });
  }
}
