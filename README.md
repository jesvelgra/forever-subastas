# Forever Subastas

Analizador de la casa de subastas de **World of Warcraft: Forever** (Europa, Alianza).

Cada hora, un proceso automático de GitHub descarga las subastas desde la API oficial de Blizzard, resume los precios de cada objeto y estima qué se ha vendido de verdad comparando con la hora anterior. Con ese historial se calcula:

- cuándo (día de la semana y hora) conviene comprar y vender cada cosa;
- cuántas unidades se venden realmente al día y a qué precio;
- qué recetas de tus profesiones dejan más beneficio.

## Puesta en marcha (una sola vez)

1. **Claves de Battle.net.** En develop.battle.net, dentro de tu cliente de API, copia el *Client ID* y el *Client Secret*.
2. **Guardarlas en GitHub.** En este repositorio: **Settings → Secrets and variables → Actions → New repository secret**. Crea dos secretos:
   - `BLIZZARD_CLIENT_ID` con el Client ID
   - `BLIZZARD_CLIENT_SECRET` con el Client Secret
3. **Primera ejecución.** Pestaña **Actions → Recolector de subastas → Run workflow**. A partir de ahí se ejecuta solo cada hora.

## Qué se guarda

En `datos/AAAA/MM/DD/` aparece un fichero por hora y casa de subastas (`_c` = bienes comerciables como hierbas o pociones, `_i` = objetos sueltos como equipo). Cada fila es un objeto:

| Columna | Significado |
|---|---|
| `ts` | momento de la descarga (UTC) |
| `casa` | casa de subastas |
| `item` | id del objeto |
| `n`, `cant` | subastas activas y unidades a la venta |
| `min`, `p10`, `p25`, `p50` | precio por unidad en cobre: mínimo, percentiles 10 y 25 y mediana |
| `nuevas` | unidades puestas a la venta desde la hora anterior |
| `vend_seg` | unidades vendidas seguro (alguien compró parte de un lote) |
| `vend_prob` | unidades vendidas muy probablemente (desaparecieron siendo las más baratas) |
| `valor_vend` | cobre total de esas ventas |
| `retiradas` | desaparecieron antes de caducar pero no eran las más baratas (venta o retirada) |
| `caducadas` | desaparecieron y pudieron caducar |
| `horas` | horas desde la descarga anterior |

La API no dice qué se vende: las ventas son una estimación. Las compras parciales de un lote son seguras; el resto, muy probables.

`datos/casas.json` lista los conjuntos de reglas y las casas de subastas que devuelve la API.

## El addon (en el juego)

`addon/ForeverSubastas` se copia en `World of Warcraft\_forever_\Interface\AddOns`. Cada hora el análisis publica un `Datos.lua` nuevo en la release **datos** de este repositorio, y el PC lo descarga solo con la tarea programada que crea `actualizar/instalar.bat` (doble clic una vez).

En el juego:

- **Tooltip de cualquier objeto:** mínimo actual, precio habitual de las últimas 24 h, precio al que se vende de verdad, ventas al día y las horas/días más baratos y más caros.
- **/subastas** abre una ventana con tres pestañas:
  - **Qué fabricar** (también con el botón *Rentabilidad* de la ventana de profesiones): recetas ordenadas por beneficio, con coste, venta neta tras el 5 % de la subasta, ventas al día y tendencia del producto. Las recetas que conoces salen en blanco. **Clic en una receta** crea la lista de la compra en Auctionator (descuenta lo que ya tienes, separa lo que se compra al vendedor y pone un precio máximo del 20 % sobre el habitual).
  - **Qué vender** (también con el botón de la subasta): lo que llevas en las bolsas, a cuánto ponerlo, probabilidad de venta, total y un consejo (ponlo ya, espera, mejor al vendedor, casi no se vende).
  - **Mis cuentas**: tus ventas y compras reales (facturas del buzón y compras de bienes en la subasta), lo que has publicado, balance por producto y evolución de tu oro. Periodo de 7 días, 30 días o todo.

Las mejores horas aparecen con 3 días de historial, los mejores días de la semana con 14 y la probabilidad de venta según el precio cuando se acumulan suficientes subastas terminadas (unos días).

## Probabilidad de venta según el precio

El recolector guarda para cada subasta su precio respecto al precio habitual (p10) cuando apareció, y al terminar si se vendió o caducó. En `datos/tramos/` se acumulan las unidades vendidas y caducadas por tramo (≤0,95; ≤1; ≤1,05; ≤1,1; ≤1,2; ≤1,35; ≤1,5; ≤2; más). El análisis recomienda el precio que maximiza lo que esperas cobrar (precio × probabilidad de venta), usando la curva propia del objeto mezclada con la general.

## Ajustes opcionales

En **Settings → Secrets and variables → Actions → Variables** se pueden crear:

- `CASAS`: ids de casa separados por comas para recoger solo esas (cuando sepamos cuál es la tuya, para no acumular datos de otras).
- `REGION`: `eu` por defecto.
- `FACCION`: `Alliance` por defecto.

## Pruebas

```
python -m unittest discover -s recolector
python addon/prueba_addon.py      # necesita: pip install lupa
```
