"""Descarga los datos fijos de WoW Forever: profesiones, recetas y objetos.

Se ejecuta una vez por semana (o a mano). Guarda datos/estaticos/recetas.json
con los nombres en español.
"""

from __future__ import annotations

import csv
import gzip
import json
import os
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from recolector import Api, ErrorApi, _nombre

LOCALE = "es_ES"


def nombre_es(valor) -> str:
    if isinstance(valor, dict):
        return valor.get("es_ES") or _nombre(valor)
    return str(valor or "")


PREFIJOS = ("Patrón", "Receta", "Plano", "Diseño", "Fórmula", "Manual", "Esquema", "Libro", "Tomo", "Pergamino")


def nombre_receta_de_patron(nombre: str) -> str:
    """'Patrón: Telar' -> 'Telar'. Si no hay prefijo conocido, devuelve el nombre tal cual."""
    if ": " in nombre:
        prefijo, resto = nombre.split(": ", 1)
        if any(prefijo.startswith(p) for p in PREFIJOS):
            return resto.strip()
    return nombre.strip()


def enlazar_patrones(patrones: dict, recetas: dict) -> int:
    """Añade a cada receta el objeto que la enseña (patron) y el nivel de profesión necesario."""
    por_nombre: dict[str, list] = {}
    for rid, r in recetas.items():
        por_nombre.setdefault(r.get("nombre", "").lower(), []).append(rid)
    n = 0
    for iid, pat in patrones.items():
        candidatas = por_nombre.get(nombre_receta_de_patron(pat["n"]).lower(), [])
        if pat.get("prof"):
            candidatas = [rid for rid in candidatas if recetas[rid].get("prof") == pat["prof"]] or candidatas
        for rid in candidatas:
            recetas[rid]["patron"] = iid
            if pat.get("nivel"):
                recetas[rid]["nivel_req"] = pat["nivel"]
            n += 1
    return n


def objetos_vistos_en_subasta(dir_datos: Path, casa: int, dias: int = 10) -> set[int]:
    """Objetos que han aparecido en la subasta en los últimos días (de los resúmenes horarios)."""
    ficheros = sorted(dir_datos.glob(f"*/*/*/*_casa{casa}_*.csv.gz"))[-dias * 48:]
    vistos: set[int] = set()
    for ruta in ficheros[::6]:  # con uno de cada seis basta: los objetos se repiten mucho
        with gzip.open(ruta, "rt", encoding="utf-8") as f:
            for fila in csv.DictReader(f):
                vistos.add(int(fila["item"]))
    if ficheros:
        with gzip.open(ficheros[-1], "rt", encoding="utf-8") as f:
            for fila in csv.DictReader(f):
                vistos.add(int(fila["item"]))
    return vistos


def main() -> int:
    client_id = os.environ.get("BLIZZARD_CLIENT_ID", "").strip()
    client_secret = os.environ.get("BLIZZARD_CLIENT_SECRET", "").strip()
    if not client_id or not client_secret:
        print("Faltan BLIZZARD_CLIENT_ID y BLIZZARD_CLIENT_SECRET.")
        return 1
    region = os.environ.get("REGION", "eu").strip() or "eu"
    salida = Path(os.environ.get("DIR_DATOS", "datos")) / "estaticos" / "recetas.json"

    api = Api(client_id, client_secret, region)
    ns = f"static-forever-{region}"

    def get(ruta):
        try:
            datos, _ = api.get(ruta, locale=LOCALE, ns=ns)
            return datos
        except ErrorApi as e:
            if e.estado != 404:
                print(f"  aviso: {ruta}: {e}")
            return None

    indice = get("/data/wow/profession/index") or {}
    profesiones = []
    recetas_por_id: dict[int, dict] = {}
    for p in indice.get("professions", []):
        info = get(f"/data/wow/profession/{p['id']}") or {}
        tiers = info.get("skill_tiers") or []
        prof = {"id": p["id"], "nombre": nombre_es(p.get("name")),
                "tipo": (info.get("type") or {}).get("type", ""), "niveles": []}
        for t in tiers:
            tier = get(f"/data/wow/profession/{p['id']}/skill-tier/{t['id']}") or {}
            prof["niveles"].append({"id": t["id"], "nombre": nombre_es(t.get("name")),
                                    "min": tier.get("minimum_skill_level"),
                                    "max": tier.get("maximum_skill_level")})
            for cat in tier.get("categories") or []:
                for r in cat.get("recipes") or []:
                    recetas_por_id[r["id"]] = {"prof": p["id"], "nivel": t["id"],
                                               "cat": nombre_es(cat.get("name")),
                                               "nombre": nombre_es(r.get("name"))}
        profesiones.append(prof)
        print(f"  {prof['nombre']}: {len(tiers)} niveles")
    print(f"Recetas en las profesiones: {len(recetas_por_id)}")

    def leer_receta(rid):
        return rid, get(f"/data/wow/recipe/{rid}")

    items_nombres: dict[int, str] = {}
    with ThreadPoolExecutor(max_workers=8) as ex:
        for rid, d in ex.map(leer_receta, list(recetas_por_id)):
            rec = recetas_por_id[rid]
            if not d:
                rec["error"] = True
                continue
            crafted = d.get("crafted_item") or d.get("alliance_crafted_item")
            if crafted:
                rec["item"] = crafted["id"]
                items_nombres[crafted["id"]] = nombre_es(crafted.get("name"))
            cq = d.get("crafted_quantity") or {}
            rec["cant"] = cq.get("value") or ((cq.get("minimum", 1) + cq.get("maximum", 1)) / 2 if cq else 1)
            rec["reag"] = []
            for r in d.get("reagents") or []:
                reag = r.get("reagent") or {}
                if "id" in reag:
                    rec["reag"].append([reag["id"], r.get("quantity", 1)])
                    items_nombres[reag["id"]] = nombre_es(reag.get("name"))
            if d.get("rank"):
                rec["rango"] = d["rank"]

    def leer_item(iid):
        return iid, get(f"/data/wow/item/{iid}")

    items: dict[int, dict] = {}
    fallos = 0
    with ThreadPoolExecutor(max_workers=8) as ex:
        for iid, d in ex.map(leer_item, list(items_nombres)):
            it = {"n": items_nombres[iid]}
            if d:
                it.update({
                    "n": nombre_es(d.get("name")) or it["n"],
                    "cal": (d.get("quality") or {}).get("type", ""),
                    "compra": d.get("purchase_price"),
                    "lote": d.get("purchase_quantity"),
                    "venta": d.get("sell_price"),
                    "clase": nombre_es((d.get("item_class") or {}).get("name")),
                    "nivel": d.get("level"),
                })
            else:
                fallos += 1
            items[iid] = it
    print(f"Objetos: {len(items)} ({fallos} sin ficha en la API)")

    # Patrones, recetas, planos... que se han visto en la subasta: precio, nivel necesario y a qué receta enseñan.
    vistos = objetos_vistos_en_subasta(salida.parent.parent, int(os.environ.get("CASA", "110")))
    pendientes = [i for i in vistos if i not in items]
    print(f"Objetos vistos en la subasta sin ficha: {len(pendientes)}")
    patrones = {}
    with ThreadPoolExecutor(max_workers=8) as ex:
        for iid, d in ex.map(leer_item, pendientes):
            if not d or (d.get("item_class") or {}).get("id") != 9:
                continue
            req = ((d.get("preview_item") or {}).get("requirements") or {}).get("skill") or {}
            patrones[iid] = {"n": nombre_es(d.get("name")), "nivel": req.get("level"),
                             "prof": (req.get("profession") or {}).get("id"), "venta": d.get("sell_price"),
                             "cal": (d.get("quality") or {}).get("type", "")}
    enlazados = enlazar_patrones(patrones, recetas_por_id)
    print(f"Patrones en la subasta: {len(patrones)}, enlazados con su receta: {enlazados}")
    for iid, pat in patrones.items():
        items[iid] = {"n": pat["n"], "cal": pat["cal"], "venta": pat["venta"], "clase": "Receta", "nivel_req": pat["nivel"]}

    salida.parent.mkdir(parents=True, exist_ok=True)
    datos = {"profesiones": profesiones,
             "recetas": {str(k): v for k, v in sorted(recetas_por_id.items())},
             "items": {str(k): v for k, v in sorted(items.items())}}
    salida.write_text(json.dumps(datos, ensure_ascii=False, separators=(",", ":")), "utf-8")
    print(f"Guardado {salida} ({salida.stat().st_size // 1024} KB)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
