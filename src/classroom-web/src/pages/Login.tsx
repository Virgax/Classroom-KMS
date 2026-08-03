import { useState } from 'react'
import { login, ApiError } from '../lib/api'

/* Login de piso: codigo de empleado (DR####) + PIN.
   Pensado para tablet/kiosko: campos grandes, teclado numerico para el PIN. */
export default function Login({ onLogin }: { onLogin: () => void }) {
  const [code, setCode] = useState('')
  const [pin, setPin] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  async function submit(e: React.FormEvent) {
    e.preventDefault()
    if (busy) return
    setBusy(true)
    setError(null)
    try {
      await login(code.trim().toUpperCase(), pin)
      onLogin()
    } catch (err) {
      setError(err instanceof ApiError ? err.message : 'No se pudo conectar con el servidor.')
      setPin('')
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="min-h-screen bg-slate-900 flex items-center justify-center p-6">
      <div className="w-full max-w-md">
        <div className="text-center mb-8">
          <div className="inline-flex items-center justify-center w-16 h-16 rounded-2xl bg-sky-500 text-white text-3xl font-black mb-4">
            A
          </div>
          <h1 className="text-3xl font-bold text-white">Classroom</h1>
          <p className="text-slate-400 mt-1">Airlink Distribution DR</p>
        </div>

        <form onSubmit={submit} className="bg-white rounded-2xl shadow-xl p-8 space-y-6">
          <div>
            <label htmlFor="code" className="block text-sm font-semibold text-slate-700 mb-2">
              Código de empleado
            </label>
            <input
              id="code"
              type="text"
              autoComplete="username"
              autoCapitalize="characters"
              placeholder="DR0000"
              value={code}
              onChange={(e) => setCode(e.target.value)}
              className="w-full text-2xl tracking-widest text-center font-mono rounded-xl border-2 border-slate-300 px-4 py-4 focus:border-sky-500 focus:outline-none uppercase"
              required
            />
          </div>

          <div>
            <label htmlFor="pin" className="block text-sm font-semibold text-slate-700 mb-2">
              PIN <span className="font-normal text-slate-500">(últimos 4 de tu cédula)</span>
            </label>
            <input
              id="pin"
              type="password"
              inputMode="numeric"
              pattern="[0-9]*"
              maxLength={8}
              autoComplete="current-password"
              placeholder="••••"
              value={pin}
              onChange={(e) => setPin(e.target.value.replace(/\D/g, ''))}
              className="w-full text-2xl tracking-[0.5em] text-center font-mono rounded-xl border-2 border-slate-300 px-4 py-4 focus:border-sky-500 focus:outline-none"
              required
            />
          </div>

          {error && (
            <div role="alert" className="rounded-xl bg-red-50 border border-red-200 text-red-700 px-4 py-3 text-sm font-medium">
              {error}
            </div>
          )}

          <button
            type="submit"
            disabled={busy || code.length < 3 || pin.length < 4}
            className="w-full rounded-xl bg-sky-600 hover:bg-sky-700 disabled:bg-slate-300 text-white text-xl font-bold py-4 transition-colors"
          >
            {busy ? 'Verificando…' : 'Entrar'}
          </button>
        </form>

        <p className="text-center text-slate-500 text-sm mt-6">
          ¿Problemas para entrar? Contacta a tu supervisor.
        </p>
      </div>
    </div>
  )
}
