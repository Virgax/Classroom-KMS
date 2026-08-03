import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'

// El proxy de dev evita CORS: /api y /health van al Classroom.Api local.
export default defineConfig({
  plugins: [react(), tailwindcss()],
  server: {
    proxy: {
      '/api': 'http://127.0.0.1:5088',
      '/health': 'http://127.0.0.1:5088',
    },
  },
})
