# Billar Control Pro 3.0

Sistema para un billar con 1 tablet CENTRAL y 5 tablets de mesa.

## Tarifas
- Mesa 1: C$100/h
- Mesa 2: C$100/h
- Mesa 3: C$100/h
- Mesa 4: C$100/h
- Mesa 5: C$70/h

## Regla de privacidad por mesa
El servidor central mantiene un WebSocket por mesa. Cuando una partida inicia, finaliza o se limpia, solo se envía el estado al dispositivo registrado con ese `tableId`. Por lo tanto, si finaliza Mesa 3, el resultado se ve en CENTRAL y MESA 3; las otras mesas no reciben ese estado.

## Instalación
El mismo APK se instala en las seis tablets. En el primer inicio se elige CENTRAL o TABLET DE MESA. Para una mesa se selecciona Mesa 1–5 y se introduce la IP local de CENTRAL.

## Compilación desde celular
El archivo `.github/workflows/build-apk.yml` genera automáticamente la plataforma Android, instala Flutter estable, obtiene dependencias, analiza el proyecto y genera un APK universal. En GitHub: Actions → Billar Control Pro - APK → Run workflow. Al terminar, descargar el artifact `Billar-Control-Pro-v3.0-APK`.

## Red local
Las 6 tablets deben estar en la misma red Wi-Fi. CENTRAL muestra su IP local y escucha en el puerto 8080. Las tablets de mesa se reconectan automáticamente si se pierde el Wi-Fi.

## Nota de seguridad
El APK generado por este workflow es para instalación directa/sideload. Para publicar en Google Play o distribuir comercialmente con una firma propia, configura un keystore de release.
