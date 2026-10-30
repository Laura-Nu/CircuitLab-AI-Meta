# Diagnóstico con una placa conectada por USB

Puedes comprobar varios sensores y módulos de una misma placa. Cada cantidad tiene
su propio canal: por ejemplo, temperatura y humedad del DHT11, identificación del
RC522 y estado del GPS. El proyecto admite hasta 32 comprobaciones por sesión.

## Recorrido en la web

1. Describe la placa y sus módulos; confirma conexiones y criterios esperados.
2. En la sesión, abre **USB de la placa** y elige la velocidad usada por su programa.
3. Pulsa conectar. En la ventana del navegador selecciona la fila del puerto y pulsa
   **Conectar**. Que un puerto aparezca como **Paired/Emparejado** solo indica un
   permiso anterior: todavía hay que seleccionarlo y abrirlo.
4. La web muestra los canales que comunica el programa. Vincula cada canal a la
   comprobación correspondiente, respetando el tipo de dato y la unidad. Esta
   asociación se conserva mientras mantengas abierta la conexión en la sesión;
   vuelve a confirmarla si conectas otra placa o reabres el puerto.
5. Confirma que se cumplen las condiciones de la prueba y activa el registro
   automático. Para la comprobación solicitada, una muestra nueva se guarda con
   origen **Informado por la placa** y el diagnóstico continúa automáticamente.
6. Realiza las acciones físicas y la prueba funcional cuando se soliciten. Una
   lectura correcta de un sensor no demuestra por sí sola que todo el montaje funcione.

Los canales se reciben juntos; el diagnóstico registra la comprobación que necesita
en ese momento. No ejecuta un análisis por cada línea recibida. Se detiene el registro
durante el análisis, al terminar la sesión o al desconectar. Al cambiar de prueba se
espera una muestra nueva: un valor antiguo del monitor no se presenta como actual.
Si un canal envía una muestra inválida, se descarta su valor anterior y se muestra
el problema hasta recibir otro dato válido.

Si no llegan canales, revisa que el programa esté enviando datos, la velocidad sea
la misma y ningún monitor del IDE u otra pestaña esté usando el puerto. Mantén
visible la pestaña y la sesión iniciada. El navegador solicita permiso por una
acción del usuario; la web no puede aceptar esa ventana automáticamente.
La [documentación de Web Serial de Chrome](https://developer.chrome.com/docs/capabilities/serial)
explica la selección y apertura del puerto y la velocidad de comunicación.

## Qué reconoce la aplicación

El USB identifica una interfaz de la placa. No enumera automáticamente los sensores
conectados a GPIO, SPI, I²C o UART: el programa debe leerlos con sus controladores y
comunicar qué dato envía. El nombre mostrado del sensor es **declarado por el
firmware**, no una comprobación independiente de su modelo o cableado.

Por eso no hay una lista cerrada de sensores. Otro módulo puede participar si su
programa entrega un canal, un valor válido y una unidad explícitos. Puedes usar
Arduino UNO, ESP32, Pico u otra placa que exponga un puerto serie compatible. Una
Raspberry Pi con Linux necesita una interfaz serie configurada o un adaptador
adecuado; conectarla mediante cualquier cable USB no garantiza un puerto de datos.
Se requiere un navegador de escritorio compatible con Web Serial y una conexión
segura a la web. Este recorrido no instala programas ni carga firmware.

**Dispositivos → Instrumento USB** es otro recorrido: utiliza el firmware de medida
TP1/A0, TP2/A1 y TP3/A2 para voltaje o estado eléctrico. No decodifica el RC522 ni el
GPS de un programa distinto. El instrumento y el monitor no pueden abrir el mismo
puerto a la vez.

## Salida que debe enviar el programa

Envía un objeto JSON completo por línea, seguido por un salto de línea. Ejemplo de
formato —los números de este ejemplo no son lecturas de tu montaje—:

```json
{"circuitlab":1,"channel":"dht11.temperature","value":23.5,"unit":"°C","sensor":"DHT11","board":"Arduino UNO","label":"Temperatura"}
```

| Campo | Contenido |
|---|---|
| `circuitlab` | Número `1`, versión del formato. |
| `channel` | Identificador estable y único de 1–80 caracteres: letras, números, `_`, `.`, `:`, `/` o `-`; empieza por letra o número. |
| `value` | Número JSON finito, booleano `true`/`false` o texto no vacío, según la unidad. |
| `unit` | Unidad exacta de la comprobación, de 1–24 caracteres. Usa `boolean` para estados y `text` para códigos o mensajes. |
| `sensor`, `board`, `label` | Opcionales: sensor declarado, placa y nombre legible. Límites respectivos: 80, 120 y 120 caracteres. |

Cada línea admite hasta 500 caracteres; no agregues otros campos. El monitor
conserva hasta 32 canales distintos. `false` y `0` son valores reales y no se
descartan por equivaler a falso. `NaN`, infinito, valores ausentes y números
escritos como texto no son lecturas numéricas válidas. `V` admite 0–5 y `mV` 0–5000;
las demás cantidades usan su propia unidad y el criterio confirmado.

Un DHT11 puede emitir `dht11.temperature` en `°C` y `dht11.humidity` en `%`; el RC522
puede emitir `rc522.uid` como `text`; el GPS puede emitir `gps.fix` como `boolean`.
No declares una posición válida si el receptor aún no tiene fijación.

Este fragmento se integra **después de que tu programa haya leído los módulos**.
Recibe valores reales de tus controladores; no sustituye sus bibliotecas ni define
lecturas de prueba:

```cpp
#include <math.h>

// Llamar con datos recién adquiridos. uidHex contiene solo el UID hexadecimal.
void enviarDatos(float temperaturaC, float humedad, bool gpsFix,
                 const String& uidHex) {
  if (isfinite(temperaturaC)) {
    Serial.print(F("{\"circuitlab\":1,\"channel\":\"dht11.temperature\",\"sensor\":\"DHT11\",\"unit\":\"°C\",\"value\":"));
    Serial.print(temperaturaC, 2);
    Serial.println('}');
  }
  if (isfinite(humedad)) {
    Serial.print(F("{\"circuitlab\":1,\"channel\":\"dht11.humidity\",\"sensor\":\"DHT11\",\"unit\":\"%\",\"value\":"));
    Serial.print(humedad, 2);
    Serial.println('}');
  }
  Serial.print(F("{\"circuitlab\":1,\"channel\":\"gps.fix\",\"unit\":\"boolean\",\"value\":"));
  Serial.print(gpsFix ? F("true") : F("false"));
  Serial.println('}');
  if (uidHex.length() > 0) {
    Serial.print(F("{\"circuitlab\":1,\"channel\":\"rc522.uid\",\"unit\":\"text\",\"value\":\""));
    Serial.print(uidHex);
    Serial.println(F("\"}"));
  }
}
```

Inicializa la salida una vez en tu `setup()` con `Serial.begin(115200)`, o la
velocidad que vayas a elegir en la web. Llama a `enviarDatos` después de actualizar
los datos reales; no reenvíes un UID antiguo ni una posición caducada como lectura
nueva. El ejemplo usa UID hexadecimal; para texto arbitrario necesitas escapar los
caracteres de JSON. Consulta las referencias oficiales de
[`Serial.begin`](https://docs.arduino.cc/language-reference/en/functions/communication/serial/begin/)
y [`Serial.println`](https://docs.arduino.cc/language-reference/en/functions/communication/serial/println/).

## Origen y resultado

Las lecturas automáticas se guardan como `serial_reported`, con el canal y los
metadatos de la trama. El servidor valida el dato, su unidad, la prueba pendiente y
su antigüedad antes de continuar. La unidad debe coincidir exactamente con la
comprobación; no se convierte voltaje en temperatura ni se adivina un módulo.

El texto libre sigue disponible como captura para analizar, sin convertirse por sí
solo en una lectura. Las capturas tienen su límite de veinte por sesión; ese límite
no es el transporte de las lecturas automáticas. Ni el texto ni un sensor que
declara estar bien acreditan una calibración o una reparación física completa.
