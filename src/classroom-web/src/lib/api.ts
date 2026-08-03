/* Cliente del Classroom.Api. El token JWT vive en localStorage. */

const TOKEN_KEY = 'kms.token'
const NAME_KEY = 'kms.displayName'

export function getToken(): string | null {
  return localStorage.getItem(TOKEN_KEY)
}

export function getDisplayName(): string | null {
  return localStorage.getItem(NAME_KEY)
}

export function clearSession(): void {
  localStorage.removeItem(TOKEN_KEY)
  localStorage.removeItem(NAME_KEY)
}

export class ApiError extends Error {
  constructor(public status: number, message: string) {
    super(message)
  }
}

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  const headers = new Headers(init?.headers)
  headers.set('Content-Type', 'application/json')
  const token = getToken()
  if (token) headers.set('Authorization', `Bearer ${token}`)

  const res = await fetch(path, { ...init, headers })
  if (!res.ok) {
    let message = `Error ${res.status}`
    try {
      const body = await res.json()
      if (body?.error) message = body.error
    } catch {
      /* sin cuerpo JSON */
    }
    if (res.status === 401 && getToken()) clearSession()
    throw new ApiError(res.status, message)
  }
  return res.json() as Promise<T>
}

export interface LoginResponse {
  token: string
  displayName: string
  preferredLocale: string
  mustChangePin: boolean
}

export async function login(employeeCode: string, pin: string): Promise<LoginResponse> {
  const r = await request<LoginResponse>('/api/auth/login', {
    method: 'POST',
    body: JSON.stringify({ employeeCode, pin }),
  })
  localStorage.setItem(TOKEN_KEY, r.token)
  localStorage.setItem(NAME_KEY, r.displayName)
  return r
}

/* --- Mi expediente (rpt.usp_TrainingRecord_GetForEmployee) ----------- */

export interface EmployeeHeader {
  employeeCode: string
  fullName: string
  siteName: string | null
  departmentName: string | null
  areaName: string | null
  positionName: string | null
  supervisorName: string | null
  hireDateUtc: string | null
}

export interface Certification {
  certificateNumber: string
  competencyCode: string
  competencyName: string
  levelName: string
  status: number // 1=Vigente 2=PorVencer 3=Vencida 4=Reentrenamiento 5=Revocada 6=Provisional
  issuedAtUtc: string
  expiresAtUtc: string | null
  regulatoryBasis: string | null
  criticality: number | null
}

export interface Enrollment {
  courseCode: string
  courseNameEs: string
  enrollmentStatus: number // 1=Asignado 2=EnProgreso 3=Completado 4=Vencido 5=Retirado 6=Reprobado
  dueAtUtc: string | null
  completedAtUtc: string | null
  scorePercent: number | null
  isPassed: boolean | null
}

export interface Gap {
  requirementCode: string
  competencyCode: string
  competencyName: string
  gapType: number // 1=NuncaCertificado 2=Vencida 3=PorVencer 4=Reentrenamiento 5=NivelInsuficiente 6=Revocada
  severity: number // 1=Critica 2=Mayor 3=Menor
  daysUntilExpiry: number | null
  hasActiveWaiver: boolean
}

export interface TrainingRecord {
  employee: EmployeeHeader
  certifications: Certification[]
  enrollments: Enrollment[]
  openGaps: Gap[]
}

export function getMyRecord(): Promise<TrainingRecord> {
  return request<TrainingRecord>('/api/me/record')
}
