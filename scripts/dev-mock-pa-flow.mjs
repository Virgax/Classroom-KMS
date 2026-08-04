/* =====================================================================
   Mock LOCAL del flow de Power Automate (SP_Hub_ValidateLogin) para
   desarrollo. Mismo contrato de entrada/salida que el flow real.
   Valida contra el mock de SPN (cedulas de database/dev/mock_spn.sql).

   Uso:  node scripts/dev-mock-pa-flow.mjs   (escucha en :7071)
   API:  KMS_PA_LOGIN_URL=http://127.0.0.1:7071/
   ===================================================================== */
import { createServer } from 'node:http'

// codigo -> { lastFour (ultimos 4 de cedula del mock SPN), datos }
const HUB = {
  DR0001: { lastFour: '5671', name: 'Ramona Peralta Gomez', email: 'rperalta@airlink.com.do', position: 'Gerente de Operaciones', department: 'Operaciones', reportLevel: 3 },
  DR0002: { lastFour: '6782', name: 'Jose Luis Perez Ramirez', email: 'jperez@airlink.com.do', position: 'Supervisor de Piso', department: 'Produccion', reportLevel: 2 },
  DR0003: { lastFour: '7893', name: 'Yokasta Minaya de la Cruz', email: 'yminaya@airlink.com.do', position: 'Supervisor de Calidad', department: 'Calidad', reportLevel: 2 },
  DR0104: { lastFour: '8904', name: 'Francisco Tejada Nunez', email: 'ftejada@airlink.com.do', position: 'Operador de Testing', department: 'Produccion', reportLevel: 1 },
  DR0105: { lastFour: '9015', name: 'Carolina Baez Santana', email: 'cbaez@airlink.com.do', position: 'Operador de Testing', department: 'Produccion', reportLevel: 1 },
  DR0110: { lastFour: '4560', name: 'Randy Mejia Suriel', email: 'rmejia@airlink.com.do', position: 'Tecnico de Reparacion', department: 'Produccion', reportLevel: 1 },
}

// Avatar PNG 96x96 generado (bloques de color por empleado) en base64.
import { deflateSync } from 'node:zlib'
function crc32(buf) {
  let c, table = []
  for (let n = 0; n < 256; n++) { c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; table[n] = c >>> 0 }
  let crc = 0xffffffff
  for (const b of buf) crc = table[(crc ^ b) & 0xff] ^ (crc >>> 8)
  return (crc ^ 0xffffffff) >>> 0
}
function chunk(type, data) {
  const len = Buffer.alloc(4); len.writeUInt32BE(data.length)
  const body = Buffer.concat([Buffer.from(type), data])
  const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(body))
  return Buffer.concat([len, body, crc])
}
function avatarPng(seed) {
  const size = 96
  const hue = [...seed].reduce((a, c) => a + c.charCodeAt(0), 0) % 360
  const rgb = (h) => { const f = (n) => { const k = (n + h / 30) % 12; return Math.round(255 * (0.55 - 0.35 * Math.max(-1, Math.min(k - 3, 9 - k, 1)))) }; return [f(0), f(8), f(4)] }
  const [r, g, b] = rgb(hue)
  const rows = []
  for (let y = 0; y < size; y++) {
    const row = [0]
    for (let x = 0; x < size; x++) {
      const cx = x - size / 2, cy = y - size / 2 - 8
      const head = cx * cx + cy * cy < 22 * 22
      const body = y > 62 && Math.abs(cx) < 34 - (96 - y) / 3
      if (head || body) row.push(245, 245, 245)
      else row.push(r, g, b)
    }
    rows.push(Buffer.from(row))
  }
  const ihdr = Buffer.alloc(13)
  ihdr.writeUInt32BE(size, 0); ihdr.writeUInt32BE(size, 4)
  ihdr[8] = 8; ihdr[9] = 2 // 8-bit RGB
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', ihdr),
    chunk('IDAT', deflateSync(Buffer.concat(rows))),
    chunk('IEND', Buffer.alloc(0)),
  ]).toString('base64')
}

const server = createServer((req, res) => {
  let raw = ''
  req.on('data', (c) => (raw += c))
  req.on('end', () => {
    let out = { isValid: 'false', employeeCode: '', employeeName: '', employeeEmail: '', positionName: '', departmentName: '', reportLevel: '0', photoB64: '' }
    try {
      const { employeeCode, lastFour } = JSON.parse(raw)
      const emp = HUB[String(employeeCode).toUpperCase()]
      if (emp && emp.lastFour === String(lastFour)) {
        out = {
          isValid: 'true',
          employeeCode: String(employeeCode).toUpperCase(),
          employeeName: emp.name,
          employeeEmail: emp.email,
          positionName: emp.position,
          departmentName: emp.department,
          reportLevel: String(emp.reportLevel),
          photoB64: avatarPng(employeeCode),
        }
      }
    } catch { /* body invalido -> isValid false */ }
    res.writeHead(200, { 'Content-Type': 'application/json' })
    res.end(JSON.stringify(out))
    console.log(`[mock-pa] ${out.employeeCode || '???'} -> isValid=${out.isValid}`)
  })
})
server.listen(7071, '127.0.0.1', () => console.log('Mock PA flow en http://127.0.0.1:7071/'))
