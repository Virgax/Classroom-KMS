import { useState } from 'react'
import Login from './pages/Login'
import Dashboard from './pages/Dashboard'
import { getToken, clearSession } from './lib/api'

export default function App() {
  const [authed, setAuthed] = useState(() => getToken() !== null)

  if (!authed) return <Login onLogin={() => setAuthed(true)} />
  return (
    <Dashboard
      onLogout={() => {
        clearSession()
        setAuthed(false)
      }}
    />
  )
}
