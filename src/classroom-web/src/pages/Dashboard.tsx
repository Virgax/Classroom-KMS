import { useEffect, useState } from 'react'
import { getMyRecord, getMyPhoto, getDisplayName, ApiError } from '../lib/api'
import type { TrainingRecord, Gap, Certification, Enrollment } from '../lib/api'

const SEVERITY = ['', 'Crítica', 'Mayor', 'Menor']
const GAP_TYPE = ['', 'Nunca certificado', 'Vencida', 'Por vencer', 'Re-entrenamiento', 'Nivel insuficiente', 'Revocada']
const CERT_STATUS = ['', 'Vigente', 'Por vencer', 'Vencida', 'Re-entrenamiento', 'Revocada', 'Provisional']
const ENROLL_STATUS = ['', 'Asignado', 'En progreso', 'Completado', 'Vencido', 'Retirado', 'Reprobado']

function fmtDate(iso: string | null): string {
  if (!iso) return '—'
  return new Date(iso).toLocaleDateString('es-DO', { day: '2-digit', month: 'short', year: 'numeric' })
}

export default function Dashboard({ onLogout }: { onLogout: () => void }) {
  const [record, setRecord] = useState<TrainingRecord | null>(null)
  const [photoUrl, setPhotoUrl] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    getMyRecord()
      .then(setRecord)
      .catch((e) => {
        if (e instanceof ApiError && e.status === 401) onLogout()
        else setError(e instanceof ApiError ? e.message : 'No se pudo cargar el expediente.')
      })
    getMyPhoto()
      .then((p) => p && setPhotoUrl(`data:${p.contentType};base64,${p.photoB64}`))
      .catch(() => {})
  }, [onLogout])

  if (error)
    return (
      <Shell onLogout={onLogout}>
        <div className="rounded-xl bg-red-50 border border-red-200 text-red-700 p-6">{error}</div>
      </Shell>
    )
  if (!record)
    return (
      <Shell onLogout={onLogout}>
        <p className="text-slate-500 animate-pulse">Cargando tu expediente…</p>
      </Shell>
    )

  const { employee, openGaps, certifications, enrollments } = record
  const critical = openGaps.filter((g) => g.severity === 1 && !g.hasActiveWaiver)
  const pending = enrollments.filter((e) => e.enrollmentStatus === 1 || e.enrollmentStatus === 2)

  return (
    <Shell onLogout={onLogout} name={employee.fullName}>
      {/* Encabezado del empleado */}
      <section className="bg-white rounded-2xl shadow-sm border border-slate-200 p-6 mb-6">
        <div className="flex flex-wrap items-start justify-between gap-4">
          <div className="flex items-center gap-4">
            {photoUrl ? (
              <img
                src={photoUrl}
                alt={employee.fullName}
                className="w-16 h-16 rounded-2xl object-cover border-2 border-slate-200"
              />
            ) : (
              <div className="w-16 h-16 rounded-2xl bg-sky-100 text-sky-700 flex items-center justify-center text-xl font-black">
                {employee.fullName
                  .split(' ')
                  .slice(0, 2)
                  .map((w) => w[0])
                  .join('')}
              </div>
            )}
            <div>
              <h2 className="text-2xl font-bold text-slate-900">{employee.fullName}</h2>
              <p className="text-slate-500 font-mono">{employee.employeeCode}</p>
            </div>
          </div>
          <div className="text-sm text-slate-600 space-y-1 text-right">
            <p>{employee.positionName ?? 'Sin posición asignada'}</p>
            <p>{[employee.departmentName, employee.areaName].filter(Boolean).join(' · ') || '—'}</p>
            {employee.supervisorName && <p>Supervisor: {employee.supervisorName}</p>}
          </div>
        </div>
      </section>

      {/* Alerta de brechas criticas */}
      {critical.length > 0 && (
        <section className="bg-red-600 text-white rounded-2xl p-6 mb-6">
          <h3 className="text-lg font-bold mb-1">
            ⚠ Tienes {critical.length} {critical.length === 1 ? 'certificación crítica pendiente' : 'certificaciones críticas pendientes'}
          </h3>
          <p className="text-red-100 text-sm">
            No puedes operar las estaciones que las exigen hasta completarlas. Habla con tu supervisor.
          </p>
        </section>
      )}

      <div className="grid gap-6 lg:grid-cols-3">
        <Card title="Brechas abiertas" count={openGaps.length} tone={critical.length > 0 ? 'red' : 'green'}>
          {openGaps.length === 0 ? (
            <Empty text="Sin brechas. Estás al día ✔" />
          ) : (
            openGaps.map((g: Gap) => (
              <div key={g.requirementCode} className="py-3 border-b border-slate-100 last:border-0">
                <div className="flex items-center justify-between gap-2">
                  <p className="font-semibold text-slate-800 text-sm">{g.competencyName}</p>
                  <span
                    className={`shrink-0 text-xs font-bold px-2 py-0.5 rounded-full ${
                      g.severity === 1 ? 'bg-red-100 text-red-700' : g.severity === 2 ? 'bg-amber-100 text-amber-700' : 'bg-slate-100 text-slate-600'
                    }`}
                  >
                    {SEVERITY[g.severity]}
                  </span>
                </div>
                <p className="text-xs text-slate-500 mt-1">
                  {GAP_TYPE[g.gapType]}
                  {g.hasActiveWaiver && ' · Waiver activo (bajo supervisión)'}
                </p>
              </div>
            ))
          )}
        </Card>

        <Card title="Mis certificaciones" count={certifications.length} tone="sky">
          {certifications.length === 0 ? (
            <Empty text="Aún no tienes certificaciones." />
          ) : (
            certifications.map((c: Certification) => (
              <div key={c.certificateNumber} className="py-3 border-b border-slate-100 last:border-0">
                <div className="flex items-center justify-between gap-2">
                  <p className="font-semibold text-slate-800 text-sm">{c.competencyName}</p>
                  <span
                    className={`shrink-0 text-xs font-bold px-2 py-0.5 rounded-full ${
                      c.status === 1 ? 'bg-green-100 text-green-700' : c.status === 2 ? 'bg-amber-100 text-amber-700' : 'bg-red-100 text-red-700'
                    }`}
                  >
                    {CERT_STATUS[c.status]}
                  </span>
                </div>
                <p className="text-xs text-slate-500 mt-1 font-mono">{c.certificateNumber}</p>
                <p className="text-xs text-slate-500">
                  Nivel {c.levelName} · Vence: {fmtDate(c.expiresAtUtc)}
                </p>
              </div>
            ))
          )}
        </Card>

        <Card title="Cursos pendientes" count={pending.length} tone="amber">
          {pending.length === 0 ? (
            <Empty text="No tienes cursos pendientes." />
          ) : (
            pending.map((e: Enrollment) => (
              <div key={e.courseCode} className="py-3 border-b border-slate-100 last:border-0">
                <p className="font-semibold text-slate-800 text-sm">{e.courseNameEs}</p>
                <p className="text-xs text-slate-500 mt-1">
                  {ENROLL_STATUS[e.enrollmentStatus]} · Fecha límite: {fmtDate(e.dueAtUtc)}
                </p>
              </div>
            ))
          )}
        </Card>
      </div>
    </Shell>
  )
}

function Shell({ children, onLogout, name }: { children: React.ReactNode; onLogout: () => void; name?: string }) {
  return (
    <div className="min-h-screen bg-slate-100">
      <header className="bg-slate-900 text-white">
        <div className="max-w-6xl mx-auto px-6 py-4 flex items-center justify-between">
          <div className="flex items-center gap-3">
            <div className="w-9 h-9 rounded-xl bg-sky-500 flex items-center justify-center font-black">A</div>
            <span className="font-bold text-lg">Classroom</span>
          </div>
          <div className="flex items-center gap-4">
            {name && <span className="text-slate-300 text-sm hidden sm:block">{name ?? getDisplayName()}</span>}
            <button
              onClick={onLogout}
              className="rounded-lg bg-slate-700 hover:bg-slate-600 px-4 py-2 text-sm font-semibold transition-colors"
            >
              Salir
            </button>
          </div>
        </div>
      </header>
      <main className="max-w-6xl mx-auto px-6 py-8">{children}</main>
    </div>
  )
}

function Card({ title, count, tone, children }: { title: string; count: number; tone: 'red' | 'green' | 'sky' | 'amber'; children: React.ReactNode }) {
  const tones = {
    red: 'bg-red-600',
    green: 'bg-green-600',
    sky: 'bg-sky-600',
    amber: 'bg-amber-500',
  }
  return (
    <section className="bg-white rounded-2xl shadow-sm border border-slate-200 overflow-hidden">
      <div className="flex items-center justify-between px-5 py-4 border-b border-slate-100">
        <h3 className="font-bold text-slate-800">{title}</h3>
        <span className={`${tones[tone]} text-white text-sm font-bold min-w-8 h-8 px-2 rounded-full flex items-center justify-center`}>
          {count}
        </span>
      </div>
      <div className="px-5 py-2 max-h-96 overflow-y-auto">{children}</div>
    </section>
  )
}

function Empty({ text }: { text: string }) {
  return <p className="text-slate-400 text-sm py-6 text-center">{text}</p>
}
