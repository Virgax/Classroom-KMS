# classroom-web

React + TypeScript + Vite. Dos interfaces muy distintas en una sola app.

## Kiosco vs escritorio

No es responsive design: son dos experiencias diferentes.

**Kiosco** (`/kiosk`) — tableta en el piso, guantes puestos, iluminación mala:

- Objetivos táctiles de 64px mínimo
- Alto contraste, tipografía grande
- Flujos cortos: entrar, hacer una cosa, firmar, salir
- Auto-logout a los 10 minutos
- Sin navegación libre — el operador entra a hacer algo concreto

**Escritorio** — supervisores, Calidad, administración:

- Tablas densas, filtros, exportación
- Matriz de competencias, tableros, paquete de auditoría
- Aquí sí hay navegación completa

## Pantallas que cargan el peso

| Ruta | Qué resuelve |
|---|---|
| `/matrix` | Matriz de competencias (GAP-01). Formato largo desde el SP, pivote en el cliente. |
| `/audit/package` | Generación del paquete de evidencia (GAP-07) |
| `/kiosk/sign/:documentId` | Firma de documento controlado con tiempo mínimo de lectura |
| `/kiosk/practical/:id` | Evaluación práctica OJT, criterio por criterio, firma dual |
| `/records/:employeeCode` | Expediente completo — lo que pide el auditor |

## La matriz

Es la pantalla más pesada. El SP devuelve una fila por celda
(empleado × competencia) y el pivote se hace en el cliente porque sólo el
cliente sabe cuántas columnas caben. Con más de ~500 empleados hay que
virtualizar; paginar rompe el pivote.

Semáforo por celda usando `MatrixStatus`:

```
1 Válido → verde     2 Por vencer → ámbar    3 Vencido → rojo
4 Requiere reentrenamiento → naranja
5 No certificado → gris    6 Revocado → rojo oscuro
7 Nivel insuficiente → amarillo
```

## Firmas: el momento importa

Cuando el usuario firma, la UI tiene que mostrar **exactamente qué** está
firmando. El payload canónico que va a `aud.usp_Signature_Create` debe
corresponder a lo que se ve en pantalla. Una firma sobre algo que el usuario no
vio no vale nada frente a un auditor, aunque el hash cuadre.

## i18n

`es-DO` por defecto, `en-US` disponible. El idioma va en `Accept-Language` y el
backend hace fallback. En el kiosco, el toggle de idioma es visible y grande:
el operador lo cambia, no un administrador por él.
