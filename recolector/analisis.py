"""Analiza el historial de la subasta y genera los datos del addon.

Lee los resúmenes horarios de datos/AAAA/MM/DD/*_casa<N>_{c,i}.csv.gz y las
recetas de datos/estaticos/, y calcula por cada objeto:

- precio actual y precio de compra típico de las últimas 24 h;
- a qué precio se vende de verdad y cuántas unidades al día (últimos 7 días);
- a qué hora y qué día de la semana suele estar más barato y más caro;

y por cada receta: coste de materiales, venta neta, beneficio y ventas/día.

Escribe addon/ForeverSubastas/Datos.lua (lo que lee el juego) y
datos/analisis/recetas.csv (para consultarlo fuera del juego).
"""

from __future__ import annotations

import csv
import gzip
import json
import math
import os
import statistics
import sys
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

ZONA = ZoneInfo("Europe/Madrid")
COMISION_SUBASTA = 0.05
# Depósito de la subasta en Forever (como en Classic): 60 % de lo que paga el vendedor por 24 h, mínimo 1 plata
# por anuncio. Se devuelve si se vende y se pierde si caduca.
DEPOSITO_24H = 0.60
DEPOSITO_MINIMO = 100
PROB_VENTA_MINIMA = 0.05
# Objetos con enfriamiento largo: no se pueden fabricar a voluntad, así que no cuentan como intermedios baratos.
OBJETOS_CON_ENFRIAMIENTO = {14342, 12360, 251290, 7078, 7080, 7082, 7076, 12803, 12808}
PROFUNDIDAD_INTERMEDIOS = 3
DIAS_HISTORIAL = 28
DIAS_VENTAS = 7
MIN_DIAS_HORAS = 3      # días con datos para fiarse del patrón por horas
MIN_DIAS_SEMANA = 14    # días con datos para fiarse del patrón por día de la semana
MIN_UDS_PRECIO_REAL = 5 # ventas mínimas para usar el precio real de venta
DIAS_TRAMOS = 14        # días de historial para la probabilidad de venta por precio
MIN_UDS_CURVA_GLOBAL = 300  # unidades terminadas (vendidas o caducadas) para fiarse de la curva general
MIN_UDS_CURVA_ITEM = 20     # ... y para usar la curva propia de un objeto
SUAVIZADO_CURVA = 10        # peso de la curva general al mezclarla con la del objeto
# Precio relativo (respecto al p10 del momento) que representa cada tramo al recomendar un precio.
# Debe ir a juego con recolector.TRAMOS; el último tramo (más de 2) no se recomienda nunca.
RATIO_TRAMO = [0.95, 1.0, 1.05, 1.1, 1.2, 1.35, 1.5, 2.0]

# Materiales que venden los vendedores (por si no están en la caché de Auctionator).
VENDEDOR_CONOCIDOS = {
    159, 1179, 1205, 1645, 1708,                      # bebidas
    2320, 2321, 4291, 8343, 14341,                    # hilos
    2324, 2325, 2604, 2605, 4340, 4341, 4342, 6260, 6261, 10290,  # blanqueador y tintes
    2596, 2665, 2678, 2692, 3713, 4289,               # especias, sal, cerveza
    3371, 3372, 8925, 18256,                          # viales
    2880, 3466, 3857, 18567,                          # fundentes y carbón
    4399, 4400, 4470, 6217, 10647, 10648, 11291,      # madera, varillas, tinta, pergamino
    2928, 2930, 5173, 8923, 8924, 17020,              # venenos y polvo arcano
}


def _int(v):
    return int(v) if v not in ("", None) else None


def _hora_local(ts: datetime) -> datetime:
    return ts.astimezone(ZONA)


def listar_ficheros(dir_datos: Path, casa: int, desde: datetime) -> list[tuple[datetime, str, Path]]:
    """Ficheros de la casa desde una fecha, ordenados por momento de la descarga."""
    salida = []
    for ruta in dir_datos.glob(f"*/*/*/*_casa{casa}_*.csv.gz"):
        nombre = ruta.name
        try:
            ts = datetime.strptime(nombre[:13], "%Y%m%dT%H%M").replace(tzinfo=timezone.utc)
        except ValueError:
            continue
        tipo = nombre.rsplit("_", 1)[1][0]
        if ts >= desde:
            salida.append((ts, tipo, ruta))
    salida.sort()
    return salida


def leer_csv(ruta: Path) -> list[dict]:
    with gzip.open(ruta, "rt", encoding="utf-8") as f:
        return list(csv.DictReader(f))


class Acumulador:
    """Recorre las descargas día a día (hora de Madrid) y acumula los patrones."""

    def __init__(self):
        # Por objeto: suma y cuenta de (precio a esa hora / mediana del día), por hora.
        self.ratio_hora = defaultdict(lambda: [[0.0, 0] for _ in range(24)])
        # Por objeto: unidades vendidas por hora local y horas observadas por hora local.
        self.ventas_hora = defaultdict(lambda: [0.0] * 24)
        # Por objeto: lista de (fecha, mediana p10, unidades vendidas, valor vendido, tipo)
        self.dias = defaultdict(list)
        # Cobertura: horas observadas por (fecha, tipo) y por hora local.
        self.cobertura_dia = defaultdict(float)
        self.cobertura_hora = defaultdict(lambda: [0.0] * 24)  # por tipo
        self._dia_actual = None
        self._buffer = defaultdict(list)       # item -> [(hora, p10)]
        self._ventas_dia = defaultdict(lambda: [0, 0])  # item -> [uds, valor]
        self._tipo_item = {}

    def añadir(self, ts: datetime, tipo: str, filas: list[dict]):
        local = _hora_local(ts)
        dia = local.date()
        if self._dia_actual is not None and dia != self._dia_actual:
            self._cerrar_dia()
        self._dia_actual = dia
        horas = None
        for f in filas:
            item = int(f["item"])
            self._tipo_item[item] = tipo
            p10 = _int(f["p10"])
            if p10:
                self._buffer[item].append((local.hour, p10, _int(f["min"]) or p10))
            if f["horas"]:
                horas = float(f["horas"])
                uds = int(f["vend_seg"]) + int(f["vend_prob"])
                if uds:
                    medio = _hora_local(ts - timedelta(hours=horas / 2))
                    self.ventas_hora[item][medio.hour] += uds
                    self._ventas_dia[item][0] += uds
                    self._ventas_dia[item][1] += int(f["valor_vend"])
        if horas:
            self.cobertura_dia[(dia, tipo)] += horas
            medio = _hora_local(ts - timedelta(hours=horas / 2))
            self.cobertura_hora[tipo][medio.hour] += min(horas, 1.0)

    def _cerrar_dia(self):
        dia = self._dia_actual
        items = set(self._buffer) | set(self._ventas_dia)
        for item in items:
            obs = self._buffer.get(item, [])
            mediana = statistics.median(p for _, p, _ in obs) if obs else None
            mediana_min = statistics.median(m for _, _, m in obs) if obs else None
            if mediana and len(obs) >= 6:
                # Una observación por hora (si hay dos en la misma hora, la media).
                por_hora = defaultdict(list)
                for h, p, _ in obs:
                    por_hora[h].append(p / mediana)
                for h, rs in por_hora.items():
                    acc = self.ratio_hora[item][h]
                    acc[0] += sum(rs) / len(rs)
                    acc[1] += 1
            uds, valor = self._ventas_dia.get(item, (0, 0))
            self.dias[item].append((dia, mediana, uds, valor, self._tipo_item.get(item, "c"), mediana_min))
        self._buffer = defaultdict(list)
        self._ventas_dia = defaultdict(lambda: [0, 0])

    def terminar(self):
        if self._dia_actual is not None:
            self._cerrar_dia()
            self._dia_actual = None


def perfil_horas(acc: list[list], min_dias: int) -> list[float | None]:
    return [(s / n) if n >= min_dias else None for s, n in acc]


def mejor_y_peor(perfil: list[float | None]) -> tuple[int | None, int | None, float, float]:
    """Hora/día más barato y más caro y su diferencia (en %) con la media."""
    validos = [(v, i) for i, v in enumerate(perfil) if v is not None]
    if len(validos) < max(3, len(perfil) // 2):
        return None, None, 0.0, 0.0
    media = sum(v for v, _ in validos) / len(validos)
    barato = min(validos)
    caro = max(validos)
    return barato[1], caro[1], round((media - barato[0]) / media * 100, 1), round((caro[0] - media) / media * 100, 1)


def perfil_semana(dias: list[tuple]) -> list[float | None]:
    """Precio de cada día de la semana respecto a la mediana de su semana (lunes=0)."""
    medianas = [(d, m) for d, m, *_ in dias if m]
    if len(medianas) < MIN_DIAS_SEMANA:
        return [None] * 7
    suma = [0.0] * 7
    cuenta = [0] * 7
    for i, (d, m) in enumerate(medianas):
        ventana = [x for _, x in medianas[max(0, i - 3): i + 4]]
        ref = statistics.median(ventana)
        suma[d.weekday()] += m / ref
        cuenta[d.weekday()] += 1
    return [(s / c) if c >= 2 else None for s, c in zip(suma, cuenta)]


def tendencia_24h(serie: list[tuple[datetime, int]]) -> float | None:
    """% de cambio entre las últimas 6 h y las mismas horas del día anterior (precio p10)."""
    if not serie:
        return None
    ref = max(ts for ts, _ in serie)
    recientes = [p for ts, p in serie if ts > ref - timedelta(hours=6)]
    antes = [p for ts, p in serie if ref - timedelta(hours=30) < ts <= ref - timedelta(hours=24)]
    if len(recientes) < 2 or len(antes) < 2:
        return None
    return round((statistics.median(recientes) / statistics.median(antes) - 1) * 100, 1)


def tendencia_7d(diaria: dict, hoy) -> float | None:
    """% de cambio semanal del precio diario, con la pendiente de Theil-Sen (aguanta días raros)."""
    puntos = sorted((d, p) for d, p in diaria.items() if p and timedelta(0) <= hoy - d <= timedelta(days=7))
    if len(puntos) < 4 or (puntos[-1][0] - puntos[0][0]).days < 4:
        return None
    pendientes = []
    for i in range(len(puntos)):
        for j in range(i + 1, len(puntos)):
            dias = (puntos[j][0] - puntos[i][0]).days
            if dias:
                pendientes.append((math.log(puntos[j][1]) - math.log(puntos[i][1])) / dias)
    if not pendientes:
        return None
    return round((math.exp(statistics.median(pendientes) * 7) - 1) * 100, 1)


def cargar_historial_semilla(ruta: Path) -> dict[int, dict]:
    """Historial diario previo (escaneos de Auctionator) para tener tendencia desde el primer día."""
    if not ruta.exists():
        return {}
    with gzip.open(ruta, "rt", encoding="utf-8") as f:
        datos = json.load(f)
    salida = {}
    for item, dias in datos.get("items", {}).items():
        salida[int(item)] = {datetime.strptime(d, "%Y-%m-%d").date(): p for d, p in dias.items()}
    return salida


def leer_tramos(dir_datos: Path, casa: int, desde: datetime) -> tuple[dict, dict]:
    """Suma ventas y caducadas por (objeto, tramo) y por (tipo, tramo)."""
    por_item: dict[tuple[int, int], list[int]] = defaultdict(lambda: [0, 0])
    por_tipo: dict[tuple[str, int], list[int]] = defaultdict(lambda: [0, 0])
    for ruta in (dir_datos / "tramos").glob(f"*/*/*/*_casa{casa}_*.csv.gz"):
        try:
            ts = datetime.strptime(ruta.name[:13], "%Y%m%dT%H%M").replace(tzinfo=timezone.utc)
        except ValueError:
            continue
        if ts < desde:
            continue
        for f in leer_csv(ruta):
            v, c, tr = int(f["vendidas"]), int(f["caducadas"]), int(f["tramo"])
            a = por_item[(int(f["item"]), tr)]
            a[0] += v
            a[1] += c
            b = por_tipo[(f["tipo"], tr)]
            b[0] += v
            b[1] += c
    return por_item, por_tipo


def curva_global(por_tipo: dict, tipo: str) -> list[float | None]:
    salida = []
    for tr in range(len(RATIO_TRAMO)):
        v, c = por_tipo.get((tipo, tr), (0, 0))
        salida.append(v / (v + c) if v + c >= 30 else None)
    total = sum(sum(por_tipo.get((tipo, tr), (0, 0))) for tr in range(len(RATIO_TRAMO)))
    return salida if total >= MIN_UDS_CURVA_GLOBAL else [None] * len(RATIO_TRAMO)


def curva_item(item: int, por_item: dict, glob: list[float | None]) -> tuple[list[float | None], int]:
    """Probabilidad de venta por tramo para un objeto, mezclada con la general (suavizado bayesiano)."""
    curva = []
    total = 0
    for tr, pg in enumerate(glob):
        v, c = por_item.get((item, tr), (0, 0))
        total += v + c
        if pg is None:
            curva.append(v / (v + c) if v + c >= MIN_UDS_CURVA_ITEM else None)
        else:
            curva.append((v + SUAVIZADO_CURVA * pg) / (v + c + SUAVIZADO_CURVA))
    return curva, total


def precio_recomendado(ref: int | None, curva: list[float | None]) -> tuple[int | None, float | None, float | None]:
    """Precio que maximiza lo que esperas cobrar (precio x probabilidad de venta). Devuelve (precio, ratio, prob)."""
    if not ref:
        return None, None, None
    mejor = None
    for ratio, prob in zip(RATIO_TRAMO, curva):
        if prob is None:
            continue
        valor = ratio * prob
        if mejor is None or valor > mejor[0] + 1e-9:
            mejor = (valor, ratio, prob)
    if not mejor:
        return None, None, None
    return round(ref * mejor[1]), mejor[1], round(mejor[2] * 100)


def analizar(dir_datos: Path, casa: int, ahora: datetime | None = None, semilla: dict | None = None,
             precio_vendedor: dict | None = None) -> dict:
    ahora = ahora or datetime.now(timezone.utc)
    ficheros = listar_ficheros(dir_datos, casa, ahora - timedelta(days=DIAS_HISTORIAL))
    if not ficheros:
        raise SystemExit(f"No hay datos de la casa {casa}")

    acc = Acumulador()
    ultimo: dict[str, tuple[datetime, list[dict]]] = {}
    p10_24h = defaultdict(list)
    serie_31h = defaultdict(list)
    precio_vendedor = precio_vendedor or {}
    # Chollos: en cuántas descargas de los últimos 7 días el mínimo estuvo por debajo de lo que paga el vendedor.
    chollo_veces: dict[int, int] = defaultdict(int)
    descargas_7d: dict[str, int] = defaultdict(int)
    for ts, tipo, ruta in ficheros:
        filas = leer_csv(ruta)
        acc.añadir(ts, tipo, filas)
        ultimo[tipo] = (ts, filas)
        if precio_vendedor and ts >= ahora - timedelta(days=DIAS_VENTAS):
            descargas_7d[tipo] += 1
            for f in filas:
                if f["min"]:
                    pv = precio_vendedor.get(int(f["item"]))
                    if pv and int(f["min"]) < pv * 0.98:
                        chollo_veces[int(f["item"])] += 1
        if ts >= ahora - timedelta(hours=31):
            for f in filas:
                if f["p10"]:
                    serie_31h[int(f["item"])].append((ts, int(f["p10"])))
                    if ts >= ahora - timedelta(hours=24):
                        p10_24h[int(f["item"])].append(int(f["p10"]))
    acc.terminar()

    primero = ficheros[0][0]
    ultimo_ts = max(ts for ts, _ in ultimo.values())
    dias_historial = (ultimo_ts - primero).total_seconds() / 86400

    # Cobertura de ventas de los últimos 7 días por tipo.
    limite = (ahora - timedelta(days=DIAS_VENTAS)).astimezone(ZONA).date()
    cobertura_7d = defaultdict(float)
    for (dia, tipo), h in acc.cobertura_dia.items():
        if dia > limite:
            cobertura_7d[tipo] += h

    items: dict[int, dict] = {}
    for tipo, (ts, filas) in ultimo.items():
        for f in filas:
            if not f["min"]:
                continue
            items[int(f["item"])] = {"min": int(f["min"]), "p10": int(f["p10"]), "cant": int(f["cant"]),
                                     "n": int(f["n"]), "tipo": tipo}

    for item, lista in acc.dias.items():
        info = items.setdefault(item, {"min": None, "p10": None, "cant": 0, "n": 0, "tipo": lista[-1][4]})
        recientes = [d for d in lista if d[0] > limite]
        uds = sum(d[2] for d in recientes)
        valor = sum(d[3] for d in recientes)
        horas = cobertura_7d.get(info["tipo"], 0.0)
        info["uds7"] = uds
        info["vd"] = round(uds / horas * 24, 2) if horas >= 1 else None
        info["pv"] = round(valor / uds) if uds >= MIN_UDS_PRECIO_REAL else None
        info["dias_venta"] = sum(1 for d in recientes if d[2] > 0)

        perfil = perfil_horas(acc.ratio_hora[item], MIN_DIAS_HORAS) if item in acc.ratio_hora else [None] * 24
        bh, sh, ab, as_ = mejor_y_peor(perfil)
        info.update(bh=bh, sh=sh, ab=ab, as_=as_)
        bd, sd, adb, ads = mejor_y_peor(perfil_semana(lista))
        info.update(bd=bd, sd=sd, adb=adb, ads=ads)

    for item, valores in p10_24h.items():
        if item in items:
            items[item]["cmp"] = int(statistics.median(valores))

    # Hora con más ventas (por hora observada), con al menos 3 días de historial.
    if dias_historial >= MIN_DIAS_HORAS:
        for item, ventas in acc.ventas_hora.items():
            if item not in items or sum(ventas) < 20:
                continue
            cob = acc.cobertura_hora.get(items[item]["tipo"], [0.0] * 24)
            ritmo = [(v / c) if c >= MIN_DIAS_HORAS else -1 for v, c in zip(ventas, cob)]
            items[item]["hv"] = max(range(24), key=lambda h: ritmo[h]) if max(ritmo) > 0 else None

    por_item_tr, por_tipo_tr = leer_tramos(dir_datos, casa, ahora - timedelta(days=DIAS_TRAMOS))
    curvas_glob = {t: curva_global(por_tipo_tr, t) for t in ("c", "i")}
    for item, info in items.items():
        curva, total = curva_item(item, por_item_tr, curvas_glob.get(info["tipo"], [None] * len(RATIO_TRAMO)))
        ref = info.get("cmp") or info.get("p10")
        precio, ratio, prob = precio_recomendado(ref, curva)
        info.update(rec=precio, rec_prob=prob)
        if total >= MIN_UDS_CURVA_ITEM and all(x is not None for x in curva):
            info["curva"] = [round(x * 100) for x in curva]

    for item, info in items.items():
        pv = precio_vendedor.get(item)
        if pv:
            info["vend"] = pv
            n = descargas_7d.get(info["tipo"], 0)
            info["chollo_pct"] = round(chollo_veces.get(item, 0) / n * 100) if n else None

    hoy = ultimo_ts.astimezone(ZONA).date()
    semilla = semilla or {}
    for item, info in items.items():
        info["t24"] = tendencia_24h(serie_31h.get(item, []))
        diaria = dict(semilla.get(item, {}))
        for d in acc.dias.get(item, []):
            if d[5]:
                diaria[d[0]] = d[5]
        info["t7"] = tendencia_7d(diaria, hoy)

    # Perfil general del mercado (media de los objetos con datos, ponderada por ventas).
    mercado_h = [[0.0, 0.0] for _ in range(24)]
    for item, horas in acc.ratio_hora.items():
        peso = 1.0 + (items.get(item, {}).get("uds7") or 0) ** 0.5
        for h, (s, n) in enumerate(horas):
            if n >= MIN_DIAS_HORAS:
                mercado_h[h][0] += s / n * peso
                mercado_h[h][1] += peso
    precio_h = [round(s / w, 4) if w else None for s, w in mercado_h]
    ventas_h_tot = [0.0] * 24
    for item, v in acc.ventas_hora.items():
        for h in range(24):
            ventas_h_tot[h] += v[h]
    cob_h = [sum(acc.cobertura_hora[t][h] for t in acc.cobertura_hora) for h in range(24)]
    ritmo_h = [round(v / c, 1) if c else None for v, c in zip(ventas_h_tot, cob_h)]

    curvas_pct = {t: [round(x * 100) if x is not None else None for x in c] for t, c in curvas_glob.items()}
    return {"casa": casa, "ahora": ahora, "ultimo": ultimo_ts, "dias": round(dias_historial, 2),
            "items": items, "mercado": {"precio_h": precio_h, "ventas_h": ritmo_h, "curvas": curvas_pct}}


# ---------------------------------------------------------------------------
# Recetas
# ---------------------------------------------------------------------------

def nombres_profesiones(estaticos: dict) -> dict[int, str]:
    """Nombre de cada profesión tal y como sale en el juego (el de su nivel: 'Sastrería', no 'Costura')."""
    salida = {}
    for p in estaticos.get("profesiones", []):
        niveles = p.get("niveles") or []
        nombre = (niveles[0].get("nombre") if len(niveles) == 1 else "") or p.get("nombre", "")
        if nombre and "[DNT]" not in nombre:
            salida[p["id"]] = nombre
    return salida


def precios_vendedor(estaticos: dict, vendedor: dict) -> dict[int, int]:
    precios = {int(k): v for k, v in vendedor.items()}
    for k, it in estaticos.get("items", {}).items():
        iid = int(k)
        if iid in VENDEDOR_CONOCIDOS and iid not in precios and it.get("compra"):
            precios[iid] = int(it["compra"] / max(1, it.get("lote") or 1))
    return precios


def precio_compra(item: int, items: dict, vendedor: dict[int, int]) -> tuple[int | None, str]:
    subasta = items.get(item, {})
    p_sub = subasta.get("cmp") or subasta.get("p10")
    p_ven = vendedor.get(item)
    if p_ven and (not p_sub or p_ven <= p_sub):
        return p_ven, "v"
    return p_sub, "s"


def precio_venta(item: int, items: dict) -> tuple[int | None, str]:
    """Precio al que se puede vender una unidad: el real si hay ventas, si no el de mercado."""
    info = items.get(item, {})
    if info.get("pv"):
        return info["pv"], "real"
    p = info.get("cmp") or info.get("p10")
    return (p, "mercado") if p else (None, "")


def nivel_requerido(r: dict) -> int | None:
    """Nivel de profesión para aprender la receta (del patrón). Ojo: "nivel" es el id del tramo de habilidad,
    salvo en ficheros antiguos donde el enlace con el patrón lo sobrescribía con el nivel."""
    if r.get("nivel_req"):
        return r["nivel_req"]
    if r.get("patron") and isinstance(r.get("nivel"), int) and r["nivel"] <= 500:
        return r["nivel"]
    return None


def indice_recetas(recetas: dict) -> dict[tuple[int, int], list[dict]]:
    """(profesión, objeto) -> recetas de esa profesión que lo fabrican."""
    idx: dict[tuple[int, int], list[dict]] = defaultdict(list)
    for r in recetas.values():
        if r.get("item") and r.get("reag"):
            idx[(r.get("prof"), r["item"])].append(r)
    return idx


def coste_unidad(item: int, prof: int, items: dict, vendedor: dict[int, int], idx: dict,
                 cache: dict, pila: tuple = ()) -> tuple[float | None, str | None, dict]:
    """Lo más barato entre comprar una unidad y fabricarla con una receta de la misma profesión.
    Devuelve (precio, fuente 'v'|'s'|'f', {material base: [cantidad por unidad, precio, fuente]})."""
    clave = (prof, item)
    if clave in cache:
        return cache[clave]
    p, fuente = precio_compra(item, items, vendedor)
    mejor = (p, fuente, {item: [1.0, p, fuente]}) if p is not None else (None, None, {})
    if item not in OBJETOS_CON_ENFRIAMIENTO and item not in pila and len(pila) < PROFUNDIDAD_INTERMEDIOS:
        for r in idx.get(clave, []):
            total, base, completa = 0.0, {}, True
            for iid, q in r["reag"]:
                pu, _, b = coste_unidad(iid, prof, items, vendedor, idx, cache, pila + (item,))
                if pu is None:
                    completa = False
                    break
                total += pu * q
                for bid, (bq, bp, bf) in b.items():
                    acum = base.setdefault(bid, [0.0, bp, bf])
                    acum[0] += bq * q
            if not completa:
                continue
            cant = r.get("cant") or 1
            unidad = total / cant
            # Fabricar solo si ahorra algo de verdad (y si no se puede comprar).
            if mejor[0] is None or unidad < mejor[0] * 0.97:
                mejor = (unidad, "f", {k: [v[0] / cant, v[1], v[2]] for k, v in base.items()})
    if not pila:
        cache[clave] = mejor
    return mejor


def deposito(item: int, cant: int, items: dict, fichas: dict) -> float:
    """Depósito de anunciar lo que sale de una fabricación durante 24 h."""
    vend = (fichas.get(str(item), {}).get("venta") or 0) * cant
    dep = vend * DEPOSITO_24H
    # Los objetos (no apilables) van de uno en uno: cada anuncio paga como mínimo 1 plata.
    if items.get(item, {}).get("tipo") == "i":
        dep = max(dep, DEPOSITO_MINIMO * cant)
    return dep


def calcular_recetas(estaticos: dict, items: dict, vendedor: dict[int, int]) -> list[dict]:
    nombres_prof = nombres_profesiones(estaticos)
    fichas = estaticos.get("items", {})
    idx = indice_recetas(estaticos.get("recetas", {}))
    cache: dict = {}
    salida = []
    for rid, r in estaticos.get("recetas", {}).items():
        if not r.get("item") or not r.get("reag") or r.get("prof") not in nombres_prof:
            continue
        coste = 0.0
        falta = []
        reag = []
        base: dict[int, list] = {}
        fabrica_algo = False
        for iid, q in r["reag"]:
            p, fuente, b = coste_unidad(iid, r["prof"], items, vendedor, idx, cache)
            reag.append([iid, q, round(p) if p is not None else None, fuente if p is not None else None])
            if p is None:
                falta.append(iid)
                continue
            coste += p * q
            fabrica_algo = fabrica_algo or fuente == "f"
            for bid, (bq, bp, bf) in b.items():
                acum = base.setdefault(bid, [0.0, bp, bf])
                acum[0] += bq * q
        cant = r.get("cant") or 1
        p_venta, origen = precio_venta(r["item"], items)
        venta_ah = p_venta * cant * (1 - COMISION_SUBASTA) if p_venta else None
        venta_vendedor = (fichas.get(str(r["item"]), {}).get("venta") or 0) * cant
        if venta_ah is None or venta_vendedor > venta_ah:
            venta, donde = venta_vendedor, "vendedor"
        else:
            venta, donde = venta_ah, origen
        info = items.get(r["item"], {})
        beneficio = venta - coste
        # Beneficio esperado: si no se vende a la primera se vuelve a anunciar y se pierde el depósito.
        # Con probabilidad P de venta por anuncio, de media se pierden (1/P - 1) depósitos.
        if donde == "vendedor":
            prob, esperado = 100, beneficio
        elif info.get("rec_prob") is not None:
            p_ok = max(PROB_VENTA_MINIMA, min(1.0, info["rec_prob"] / 100))
            prob = round(p_ok * 100)
            esperado = beneficio - (1 / p_ok - 1) * deposito(r["item"], cant, items, fichas)
        else:
            prob, esperado = None, None
        salida.append({
            "id": int(rid), "prof": r["prof"], "profesion": nombres_prof.get(r["prof"], ""),
            "nombre": r.get("nombre", ""), "item": r["item"], "cant": cant,
            "coste": round(coste), "venta": round(venta), "beneficio": round(beneficio),
            "vd": info.get("vd"), "donde": donde, "falta": falta, "reag": reag,
            "sh": info.get("sh"), "sd": info.get("sd"),
            "patron": r.get("patron"), "nivel": nivel_requerido(r),
            "base": ([[bid, round(v[0], 3), round(v[1]) if v[1] is not None else None, v[2]]
                      for bid, v in sorted(base.items())] if fabrica_algo and not falta else None),
            "esperado": round(esperado) if esperado is not None else None, "prob": prob,
        })
    # Primero las recetas con todos los precios conocidos.
    salida.sort(key=lambda x: (not x["falta"], x["esperado"] if x["esperado"] is not None else x["beneficio"]),
                reverse=True)
    return salida


# ---------------------------------------------------------------------------
# Salida para el addon
# ---------------------------------------------------------------------------

def _lua_str(s: str) -> str:
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ") + '"'


def _lua_val(v) -> str:
    if v is None:
        return "nil"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, float):
        return ("%.2f" % v).rstrip("0").rstrip(".")
    if isinstance(v, int):
        return str(v)
    if isinstance(v, str):
        return _lua_str(v)
    if isinstance(v, (list, tuple)):
        # Quitar nils del final para que el constructor quede limpio.
        vals = list(v)
        while vals and vals[-1] is None:
            vals.pop()
        return "{" + ",".join(_lua_val(x) for x in vals) + "}"
    raise TypeError(type(v))


def escribir_lua(ruta: Path, res: dict, recetas: list[dict], estaticos: dict) -> None:
    items = res["items"]
    fichas = estaticos.get("items", {})
    lineas = [
        "-- Generado automáticamente por forever-subastas. No editar a mano.",
        "-- i[id] = {min, compra24h, precioVentaReal, ventasDia, unidadesALaVenta,",
        "--          horaBarata, horaCara, %barata, %cara, diaBarato, diaCaro, %diaBarato, %diaCaro, diasConVenta,",
        "--          tendencia24h%, tendencia7dias%, horaConMasVentas, precioRecomendado, %ventaAEsePrecio,",
        "--          {%venta por tramo de precio}, loQuePagaElVendedor, %horasPorDebajoDelVendedor(7 días)}",
        "-- tramos de precio (respecto al precio habitual): " + ", ".join(f"{x:g}" for x in RATIO_TRAMO),
        "-- r = {{id, profesion, nombre, item, cantidad, coste, venta, beneficio, ventasDia, donde,",
        "--       {{reactivo, cantidad, precioUnidad, 'v'=vendedor|'s'=subasta}, ...}, faltanPrecios,",
        "--       objetoQueLaEnseña (patrón), nivelDeProfesiónNecesario,",
        "--       {{materialBase, cantidadPorFabricación, precioUnidad, fuente}} (solo si conviene fabricar intermedios: 'f'),",
        "--       beneficioEsperado (contando depósitos perdidos), %ventaPorAnuncio}, ...}",
        "ForeverSubastasDatos = {",
        f"  version = 1,",
        f"  casa = {res['casa']},",
        f"  generado = {_lua_str(res['ahora'].astimezone(ZONA).strftime('%d/%m %H:%M'))},",
        f"  ultimaDescarga = {_lua_str(res['ultimo'].astimezone(ZONA).strftime('%d/%m %H:%M'))},",
        f"  ultimaDescargaTs = {int(res['ultimo'].timestamp())},",
        f"  generadoTs = {int(res['ahora'].timestamp())},",
        f"  dias = {_lua_val(res['dias'])},",
        f"  mercado = {{ precioHora = {_lua_val(res['mercado']['precio_h'])}, ventasHora = {_lua_val(res['mercado']['ventas_h'])},",
        f"    curvaBienes = {_lua_val(res['mercado']['curvas'].get('c', []))}, curvaObjetos = {_lua_val(res['mercado']['curvas'].get('i', []))},",
        f"    tramos = {_lua_val(RATIO_TRAMO)} }},",
        "  i = {",
    ]
    for iid in sorted(items):
        d = items[iid]
        if not d.get("min") and not d.get("uds7"):
            continue
        fila = [d.get("min"), d.get("cmp"), d.get("pv"), d.get("vd"), d.get("cant") or 0,
                d.get("bh"), d.get("sh"), d.get("ab") or None, d.get("as_") or None,
                d.get("bd"), d.get("sd"), d.get("adb") or None, d.get("ads") or None,
                d.get("dias_venta"), d.get("t24"), d.get("t7"), d.get("hv"), d.get("rec"), d.get("rec_prob"),
                d.get("curva"), d.get("vend"), d.get("chollo_pct") or None]
        lineas.append(f"    [{iid}]={_lua_val(fila)},")
    lineas.append("  },")
    lineas.append("  p = {")
    for pid, nombre in sorted(nombres_profesiones(estaticos).items()):
        lineas.append(f"    [{pid}]={_lua_str(nombre)},")
    lineas.append("  },")
    lineas.append("  r = {")
    nombres_usados = set()
    for r in recetas:
        nombres_usados.add(r["item"])
        nombres_usados.update(x[0] for x in r["reag"])
        nombres_usados.update(x[0] for x in (r.get("base") or []))
        if r.get("patron"):
            nombres_usados.add(r["patron"])
        fila = [r["id"], r["prof"], r["nombre"], r["item"], r["cant"], r["coste"], r["venta"],
                r["beneficio"], r["vd"], r["donde"], [list(x) for x in r["reag"]],
                len(r["falta"]) if r["falta"] else None, r.get("patron"), r.get("nivel"),
                r.get("base"), r.get("esperado"), r.get("prob")]
        lineas.append(f"    {_lua_val(fila)},")
    lineas.append("  },")
    lineas.append("  n = {")
    for iid in sorted(nombres_usados):
        nombre = fichas.get(str(iid), {}).get("n")
        if nombre:
            lineas.append(f"    [{iid}]={_lua_str(nombre)},")
    lineas.append("  },")
    lineas.append("}")
    ruta.parent.mkdir(parents=True, exist_ok=True)
    ruta.write_text("\n".join(lineas) + "\n", encoding="utf-8")


def escribir_csv_recetas(ruta: Path, recetas: list[dict], estaticos: dict) -> None:
    ruta.parent.mkdir(parents=True, exist_ok=True)
    with open(ruta, "w", encoding="utf-8", newline="") as f:
        w = csv.writer(f)
        w.writerow(["profesion", "receta", "coste_oro", "venta_oro", "beneficio_oro", "beneficio_esperado_oro",
                    "prob_venta", "ventas_dia", "precio_venta_de", "faltan_precios", "fabrica_intermedios"])
        for r in recetas:
            esp = r.get("esperado")
            w.writerow([r["profesion"], r["nombre"], round(r["coste"] / 10000, 4), round(r["venta"] / 10000, 4),
                        round(r["beneficio"] / 10000, 4), round(esp / 10000, 4) if esp is not None else "",
                        r.get("prob") if r.get("prob") is not None else "",
                        r["vd"] if r["vd"] is not None else "", r["donde"], len(r["falta"]),
                        "sí" if r.get("base") else ""])


def main() -> int:
    base = Path(os.environ.get("DIR_BASE", "."))
    dir_datos = base / "datos"
    casa = int(os.environ.get("CASA", "110"))
    semilla = cargar_historial_semilla(dir_datos / "estaticos" / "auctionator_historial.json.gz")
    ruta_pv = dir_datos / "estaticos" / "precio_vendedor.json"
    precio_vendedor = {int(k): v for k, v in json.loads(ruta_pv.read_text("utf-8")).items()} if ruta_pv.exists() else {}
    res = analizar(dir_datos, casa, semilla=semilla, precio_vendedor=precio_vendedor)

    ruta_est = dir_datos / "estaticos" / "recetas.json"
    estaticos = json.loads(ruta_est.read_text("utf-8")) if ruta_est.exists() else {}
    ruta_ven = dir_datos / "estaticos" / "vendedor.json"
    vendedor_json = json.loads(ruta_ven.read_text("utf-8")).get("precios", {}) if ruta_ven.exists() else {}
    vendedor = precios_vendedor(estaticos, vendedor_json)
    recetas = calcular_recetas(estaticos, res["items"], vendedor)

    escribir_lua(base / "addon" / "ForeverSubastas" / "Datos.lua", res, recetas, estaticos)
    escribir_csv_recetas(dir_datos / "analisis" / "recetas.csv", recetas, estaticos)
    con_ventas = sum(1 for d in res["items"].values() if d.get("vd"))
    con_tendencia = sum(1 for d in res["items"].values() if d.get("t7") is not None)
    chollos = [i for i, d in res["items"].items() if d.get("vend") and d.get("min") and d["min"] < d["vend"] * 0.98]
    print(f"Chollos ahora (subasta por debajo del vendedor): {len(chollos)}")
    print(f"Casa {casa}: {res['dias']} días de historial, {len(res['items'])} objetos, "
          f"{con_ventas} con ventas medidas, {con_tendencia} con tendencia semanal, {len(recetas)} recetas")
    return 0


if __name__ == "__main__":
    sys.exit(main())
