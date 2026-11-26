"""Recolector horario de la casa de subastas de WoW Forever.

Descarga las subastas de la Alianza desde la API oficial de Blizzard
(Game Data API, espacio de nombres dynamic-forever-<región>), resume los
precios por objeto y estima qué se ha vendido comparando con la descarga
anterior.

Variables de entorno:
    BLIZZARD_CLIENT_ID, BLIZZARD_CLIENT_SECRET  (obligatorias)
    REGION       región de Battle.net (por defecto "eu")
    FACCION      texto que identifica las casas a recoger (por defecto "Alliance")
    CASAS        ids de casa separados por comas; si se indica, solo recoge esas
    DIR_DATOS    carpeta de salida de los resúmenes (por defecto "datos")
    DIR_ESTADO   carpeta con la última descarga de cada casa (por defecto "estado")

Se ejecuta desde GitHub Actions una vez por hora. Solo usa la biblioteca
estándar de Python.
"""

from __future__ import annotations

import base64
import csv
import gzip
import io
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime
from pathlib import Path

# Horas máximas que le pueden quedar a una subasta según su "time_left".
# Si una subasta desaparece antes de ese plazo, no ha podido caducar:
# se ha vendido o la han retirado.
HORAS_MAX_RESTANTES = {
    "SHORT": 0.5,
    "MEDIUM": 2.0,
    "LONG": 12.0,
    "VERY_LONG": 48.0,
}

COLUMNAS = [
    "ts",          # momento de la descarga (UTC, ISO 8601)
    "casa",        # id de la casa de subastas
    "tipo",        # c = bienes comerciables (hierbas, pociones...), i = objetos sueltos
    "item",        # id del objeto
    "n",           # número de subastas activas
    "cant",        # unidades a la venta
    "min",         # precio unitario más bajo (cobre)
    "p10",         # percentil 10 por unidades (cobre)
    "p25",         # percentil 25 por unidades (cobre)
    "p50",         # mediana por unidades (cobre)
    "nuevas",      # unidades puestas a la venta desde la descarga anterior
    "vend_seg",    # unidades vendidas seguro (compras parciales de un lote)
    "vend_prob",   # unidades vendidas muy probablemente (desaparecieron siendo las más baratas)
    "valor_vend",  # cobre total de vend_seg + vend_prob
    "retiradas",   # unidades que desaparecieron antes de caducar pero no eran las más baratas
    "caducadas",   # unidades que desaparecieron y pudieron caducar
    "horas",       # horas desde la descarga anterior (vacío si no hay anterior)
]


# ---------------------------------------------------------------------------
# Acceso a la API
# ---------------------------------------------------------------------------

class ErrorApi(Exception):
    def __init__(self, estado: int, url: str, cuerpo: str = ""):
        super().__init__(f"HTTP {estado} en {url} {cuerpo[:200]}")
        self.estado = estado


def _peticion(url: str, *, cabeceras: dict | None = None, datos: bytes | None = None,
              intentos: int = 4) -> tuple[dict, dict]:
    """Hace una petición y devuelve (json, cabeceras). Reintenta errores temporales."""
    cab = {"Accept-Encoding": "gzip", "User-Agent": "forever-subastas/1.0"}
    cab.update(cabeceras or {})
    espera = 2.0
    for intento in range(1, intentos + 1):
        req = urllib.request.Request(url, data=datos, headers=cab)
        try:
            with urllib.request.urlopen(req, timeout=120) as resp:
                cuerpo = resp.read()
                if resp.headers.get("Content-Encoding") == "gzip":
                    cuerpo = gzip.decompress(cuerpo)
                return json.loads(cuerpo), dict(resp.headers)
        except urllib.error.HTTPError as e:
            texto = e.read().decode("utf-8", "replace") if e.fp else ""
            if e.code in (429, 500, 502, 503, 504) and intento < intentos:
                time.sleep(espera)
                espera *= 2
                continue
            raise ErrorApi(e.code, url, texto) from None
        except (urllib.error.URLError, TimeoutError, ConnectionError) as e:
            if intento < intentos:
                time.sleep(espera)
                espera *= 2
                continue
            raise ErrorApi(0, url, str(e)) from None
    raise ErrorApi(0, url, "sin respuesta")


class Api:
    def __init__(self, client_id: str, client_secret: str, region: str = "eu"):
        self.region = region
        self.base = f"https://{region}.api.blizzard.com"
        self.ns = f"dynamic-forever-{region}"
        self.token = self._token(client_id, client_secret)

    @staticmethod
    def _token(client_id: str, client_secret: str) -> str:
        credenciales = base64.b64encode(f"{client_id}:{client_secret}".encode()).decode()
        datos, _ = _peticion(
            "https://oauth.battle.net/token",
            cabeceras={"Authorization": f"Basic {credenciales}",
                       "Content-Type": "application/x-www-form-urlencoded"},
            datos=b"grant_type=client_credentials",
        )
        return datos["access_token"]

    def get(self, ruta: str, locale: str = "en_GB") -> tuple[dict, dict]:
        consulta = urllib.parse.urlencode({"namespace": self.ns, "locale": locale})
        return _peticion(f"{self.base}{ruta}?{consulta}",
                         cabeceras={"Authorization": f"Bearer {self.token}"})


# ---------------------------------------------------------------------------
# Descubrir conjuntos de reglas y casas de subastas
# ---------------------------------------------------------------------------

def _nombre(valor) -> str:
    """Los nombres pueden venir como texto o como diccionario por idioma."""
    if isinstance(valor, dict):
        for clave in ("en_GB", "en_US", "es_ES"):
            if valor.get(clave):
                return valor[clave]
        return next((v for v in valor.values() if isinstance(v, str)), "")
    return str(valor or "")


def _lista_con_ids(datos: dict, clave_preferida: str) -> list[dict]:
    """Devuelve la lista de elementos con 'id' de una respuesta índice."""
    lista = datos.get(clave_preferida)
    if isinstance(lista, list):
        return lista
    for valor in datos.values():
        if isinstance(valor, list) and valor and isinstance(valor[0], dict) and "id" in valor[0]:
            return valor
    return []


def descubrir_casas(api: Api) -> tuple[list[dict], dict[int, dict]]:
    """Devuelve (conjuntos de reglas, casas). Cada casa: {nombre, conjuntos: [ids]}."""
    indice, _ = api.get("/data/wow/ruleset/index")
    conjuntos = [{"id": r["id"], "nombre": _nombre(r.get("name"))}
                 for r in _lista_con_ids(indice, "rulesets")]
    casas: dict[int, dict] = {}
    for conjunto in conjuntos:
        try:
            datos, _ = api.get(f"/data/wow/ruleset/{conjunto['id']}/auctions/")
        except ErrorApi as e:
            print(f"  aviso: no se pudo leer el índice de casas del conjunto {conjunto['id']}: {e}")
            continue
        for casa in _lista_con_ids(datos, "auctions"):
            info = casas.setdefault(casa["id"], {"nombre": _nombre(casa.get("name")), "conjuntos": []})
            info["conjuntos"].append(conjunto["id"])
    return conjuntos, casas


def es_de_faccion(nombre: str, faccion: str) -> bool:
    nombre = nombre.lower()
    alias = {"alliance": ("alliance", "alianza"), "horde": ("horde", "horda")}
    return any(a in nombre for a in alias.get(faccion.lower(), (faccion.lower(),)))


# ---------------------------------------------------------------------------
# Normalizar y resumir
# ---------------------------------------------------------------------------

def normalizar(subastas: list[dict], tipo: str) -> dict[int, tuple]:
    """Convierte la lista de la API en {id_subasta: (item, cant, precio_unidad, time_left)}.

    Las subastas solo con puja (sin precio de compra) se ignoran para los
    precios, porque no indican a cuánto se puede comprar ya.
    """
    salida: dict[int, tuple] = {}
    for s in subastas or []:
        try:
            item = s["item"]["id"]
            cant = int(s.get("quantity") or 1)
            if tipo == "c":
                unidad = s.get("unit_price")
            else:
                buyout = s.get("buyout")
                unidad = (buyout // cant) if buyout else None
            if not unidad or cant <= 0:
                continue
            salida[int(s["id"])] = (int(item), cant, int(unidad), s.get("time_left", ""))
        except (KeyError, TypeError, ValueError):
            continue
    return salida


def _percentil(precios_cant: list[tuple[int, int]], fraccion: float) -> int:
    """Percentil por unidades. precios_cant debe ir ordenado por precio."""
    total = sum(c for _, c in precios_cant)
    objetivo = max(1, fraccion * total)
    acumulado = 0
    for precio, cant in precios_cant:
        acumulado += cant
        if acumulado >= objetivo:
            return precio
    return precios_cant[-1][0]


def resumir(actual: dict[int, tuple]) -> dict[int, dict]:
    """Resumen de precios por objeto."""
    por_item: dict[int, list[tuple[int, int]]] = {}
    for item, cant, unidad, _ in actual.values():
        por_item.setdefault(item, []).append((unidad, cant))
    resumen = {}
    for item, lista in por_item.items():
        lista.sort()
        resumen[item] = {
            "n": len(lista),
            "cant": sum(c for _, c in lista),
            "min": lista[0][0],
            "p10": _percentil(lista, 0.10),
            "p25": _percentil(lista, 0.25),
            "p50": _percentil(lista, 0.50),
        }
    return resumen


def estimar_movimientos(anterior: dict[int, tuple], actual: dict[int, tuple],
                        horas: float) -> dict[int, dict]:
    """Compara dos descargas y estima ventas por objeto.

    - Un lote que sigue ahí con menos unidades: alguien ha comprado parte
      (venta segura). Solo pasa con bienes comerciables.
    - Una subasta que desaparece sin haber podido caducar:
        * si era tan barata o más que lo que queda a la venta (o que el precio
          de alguna compra parcial), es venta probable: en los bienes
          comerciables el juego vende siempre primero lo más barato, y nadie
          retira la subasta más barata;
        * si era más cara, puede ser una venta o alguien que la retiró para
          bajar el precio: cuenta como "retirada".
    - Una subasta que desaparece y sí pudo caducar cuenta como "caducada".
    """
    mov: dict[int, dict] = {}

    def fila(item: int) -> dict:
        return mov.setdefault(item, {"nuevas": 0, "vend_seg": 0, "vend_prob": 0,
                                     "valor_vend": 0, "retiradas": 0, "caducadas": 0})

    minimo_actual: dict[int, int] = {}
    for item, _, unidad, _ in actual.values():
        if item not in minimo_actual or unidad < minimo_actual[item]:
            minimo_actual[item] = unidad

    # 1) Compras parciales y precio más alto al que se ha comprado algo.
    umbral_compra: dict[int, int] = {}
    desaparecidas = []
    for id_subasta, (item, cant, unidad, tl) in anterior.items():
        ahora = actual.get(id_subasta)
        if ahora is None:
            desaparecidas.append((item, cant, unidad, tl))
            continue
        if ahora[1] < cant:
            vendidas = cant - ahora[1]
            f = fila(item)
            f["vend_seg"] += vendidas
            f["valor_vend"] += vendidas * unidad
            umbral_compra[item] = max(umbral_compra.get(item, 0), unidad)

    # 2) Subastas desaparecidas.
    for item, cant, unidad, tl in desaparecidas:
        f = fila(item)
        pudo_caducar = HORAS_MAX_RESTANTES.get(tl, 48.0) <= horas
        if pudo_caducar:
            f["caducadas"] += cant
            continue
        umbral = max(minimo_actual.get(item, 0), umbral_compra.get(item, 0))
        if item not in minimo_actual or unidad <= umbral:
            f["vend_prob"] += cant
            f["valor_vend"] += cant * unidad
        else:
            f["retiradas"] += cant

    # 3) Unidades nuevas a la venta.
    for id_subasta, (item, cant, _, _) in actual.items():
        if id_subasta not in anterior:
            fila(item)["nuevas"] += cant

    return mov


# ---------------------------------------------------------------------------
# Estado y ficheros
# ---------------------------------------------------------------------------

def _fecha_cabecera(cabeceras: dict) -> datetime | None:
    valor = cabeceras.get("Last-Modified") or cabeceras.get("last-modified")
    if not valor:
        return None
    try:
        return parsedate_to_datetime(valor).astimezone(timezone.utc)
    except (TypeError, ValueError):
        return None


def cargar_estado(ruta: Path) -> dict | None:
    if not ruta.exists():
        return None
    try:
        with gzip.open(ruta, "rt", encoding="utf-8") as f:
            datos = json.load(f)
        datos["subastas"] = {int(k): tuple(v) for k, v in datos["subastas"].items()}
        return datos
    except (OSError, ValueError, KeyError):
        return None


def guardar_estado(ruta: Path, ts: datetime, subastas: dict[int, tuple]) -> None:
    ruta.parent.mkdir(parents=True, exist_ok=True)
    with gzip.open(ruta, "wt", encoding="utf-8") as f:
        json.dump({"ts": ts.isoformat(), "subastas": {str(k): v for k, v in subastas.items()}},
                  f, separators=(",", ":"))


def filas_salida(ts: datetime, casa: int, tipo: str, resumen: dict[int, dict],
                 movimientos: dict[int, dict], horas: float | None) -> list[dict]:
    filas = []
    vacio = {"n": 0, "cant": 0, "min": "", "p10": "", "p25": "", "p50": ""}
    sin_mov = {"nuevas": 0, "vend_seg": 0, "vend_prob": 0, "valor_vend": 0,
               "retiradas": 0, "caducadas": 0}
    for item in sorted(set(resumen) | set(movimientos)):
        fila = {"ts": ts.strftime("%Y-%m-%dT%H:%M:%SZ"), "casa": casa, "tipo": tipo, "item": item}
        fila.update(resumen.get(item, vacio))
        fila.update(movimientos.get(item, sin_mov))
        fila["horas"] = "" if horas is None else round(horas, 2)
        filas.append(fila)
    return filas


def escribir_csv(ruta: Path, filas: list[dict]) -> None:
    ruta.parent.mkdir(parents=True, exist_ok=True)
    texto = io.StringIO()
    escritor = csv.DictWriter(texto, fieldnames=COLUMNAS, lineterminator="\n")
    escritor.writeheader()
    escritor.writerows(filas)
    # mtime=0 para que el mismo contenido dé siempre el mismo fichero.
    with open(ruta, "wb") as f, gzip.GzipFile(fileobj=f, mode="wb", mtime=0) as gz:
        gz.write(texto.getvalue().encode("utf-8"))


# ---------------------------------------------------------------------------
# Proceso principal
# ---------------------------------------------------------------------------

def procesar_feed(*, ts: datetime, casa: int, tipo: str, subastas_api: list[dict],
                  dir_datos: Path, dir_estado: Path) -> dict:
    """Procesa una descarga (bienes 'c' u objetos 'i') de una casa."""
    actual = normalizar(subastas_api, tipo)
    ruta_estado = dir_estado / f"casa-{casa}-{tipo}.json.gz"
    previo = cargar_estado(ruta_estado)

    horas = None
    movimientos: dict[int, dict] = {}
    if previo:
        ts_prev = datetime.fromisoformat(previo["ts"])
        if ts <= ts_prev:
            return {"saltado": True}
        horas = (ts - ts_prev).total_seconds() / 3600
        # Si el hueco es muy grande (el recolector estuvo parado) las ventas
        # no son fiables: solo se guardan precios.
        if horas <= 6:
            movimientos = estimar_movimientos(previo["subastas"], actual, horas)
        else:
            horas = None

    resumen = resumir(actual)
    filas = filas_salida(ts, casa, tipo, resumen, movimientos, horas)
    if filas:
        ruta = dir_datos / ts.strftime("%Y/%m/%d") / f"{ts:%Y%m%dT%H%M}_casa{casa}_{tipo}.csv.gz"
        escribir_csv(ruta, filas)
    guardar_estado(ruta_estado, ts, actual)

    vendidas = sum(m["vend_seg"] + m["vend_prob"] for m in movimientos.values())
    return {"saltado": False, "subastas": len(actual), "objetos": len(resumen),
            "vendidas": vendidas, "horas": horas}


def main() -> int:
    client_id = os.environ.get("BLIZZARD_CLIENT_ID", "").strip()
    client_secret = os.environ.get("BLIZZARD_CLIENT_SECRET", "").strip()
    if not client_id or not client_secret:
        print("Faltan BLIZZARD_CLIENT_ID y BLIZZARD_CLIENT_SECRET (secretos del repositorio).")
        return 1

    region = os.environ.get("REGION", "eu").strip() or "eu"
    faccion = os.environ.get("FACCION", "Alliance").strip() or "Alliance"
    dir_datos = Path(os.environ.get("DIR_DATOS", "datos"))
    dir_estado = Path(os.environ.get("DIR_ESTADO", "estado"))

    api = Api(client_id, client_secret, region)
    conjuntos, casas = descubrir_casas(api)
    lista_conjuntos = ", ".join("%s=%s" % (c["id"], c["nombre"]) for c in conjuntos)
    print(f"Conjuntos de reglas: {lista_conjuntos}")

    solo = {int(x) for x in os.environ.get("CASAS", "").replace(" ", "").split(",") if x.isdigit()}
    if solo:
        elegidas = {cid: info for cid, info in casas.items() if cid in solo}
        print(f"Casas de subastas: {len(casas)} en total, recogiendo solo {sorted(elegidas)}")
    else:
        elegidas = {cid: info for cid, info in casas.items() if es_de_faccion(info["nombre"], faccion)}
        print(f"Casas de subastas: {len(casas)} en total, {len(elegidas)} de {faccion}")
    if not elegidas:
        print("No se ha encontrado ninguna casa de esa facción. Nombres recibidos:",
              sorted({info["nombre"] for info in casas.values()}))
        return 1

    # Guardar el mapa de casas para el análisis (fichero pequeño).
    dir_datos.mkdir(parents=True, exist_ok=True)
    mapa = {"region": region, "conjuntos": conjuntos,
            "casas": {str(k): v for k, v in sorted(casas.items())}}
    (dir_datos / "casas.json").write_text(json.dumps(mapa, ensure_ascii=False, indent=1), "utf-8")

    errores = 0
    procesadas = 0
    ahora = datetime.now(timezone.utc).replace(microsecond=0)
    for casa, info in sorted(elegidas.items()):
        conjunto = info["conjuntos"][0]
        for tipo, ruta in (("i", f"/data/wow/ruleset/{conjunto}/auctions/{casa}"),
                           ("c", f"/data/wow/ruleset/{conjunto}/auctions/{casa}/commodities")):
            try:
                datos, cab = api.get(ruta)
            except ErrorApi as e:
                if e.estado == 404:
                    continue  # casa sin datos (p. ej. un conjunto que aún no ha abierto)
                print(f"  casa {casa} ({tipo}): error {e}")
                errores += 1
                continue
            subastas = datos.get("auctions")
            if not isinstance(subastas, list) or not subastas:
                continue
            ts = _fecha_cabecera(cab) or ahora
            r = procesar_feed(ts=ts, casa=casa, tipo=tipo, subastas_api=subastas,
                              dir_datos=dir_datos, dir_estado=dir_estado)
            procesadas += 1
            etiqueta = "bienes" if tipo == "c" else "objetos"
            if r["saltado"]:
                print(f"  casa {casa} {etiqueta}: sin cambios desde la última descarga")
            else:
                extra = (f", {r['vendidas']} uds. vendidas en {r['horas']:.1f} h"
                         if r["horas"] is not None else ", primera descarga (sin ventas aún)")
                print(f"  casa {casa} {etiqueta} [{ts:%d/%m %H:%M} UTC]: "
                      f"{r['subastas']} subastas, {r['objetos']} objetos{extra}")
    if errores and not procesadas:
        print("No se ha podido descargar ninguna casa.")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
