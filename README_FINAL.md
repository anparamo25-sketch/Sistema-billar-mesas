# Billar Control Pro – versión final

## Archivos principales
- `lib/main.dart`: aplicación completa.
- `.github/workflows/main.yml`: compilación Android desde GitHub Actions.

## Funciones
- 1 tablet CENTRAL + 5 tablets de MESA.
- Cada mesa solo recibe y muestra los datos de su propia mesa.
- Inicio y finalización de partidas únicamente desde CENTRAL.
- Las tablets de mesa no pueden borrar cobros, cambiar tarifas, ver historial ni cambiar PIN.
- Hora de inicio, hora de finalización, tiempo jugado y monto a pagar.
- Tarifas proporcionales al tiempo: mesas 1–4 por defecto C$100/h y mesa 5 C$70/h.
- Persistencia local de partidas, historial, tarifas, PIN y total diario.
- Historial de partidas finalizadas.
- Cierre diario protegido por PIN y bloqueado si hay partidas activas.
- Cambio de PIN desde CENTRAL.
- El PIN nunca aparece escrito automáticamente en la pantalla de acceso.
- El PIN se escribe manualmente cada vez y tiene botón para mostrar/ocultar temporalmente.
- Servidor local en puerto 8080.
- Reconexión automática de las tablets cuando se pierde la Wi-Fi.
- Manifest Android con permiso INTERNET y `usesCleartextTraffic=true`.
