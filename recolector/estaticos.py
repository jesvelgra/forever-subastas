"""Descarga los datos fijos de WoW Forever: profesiones, recetas y objetos.

Se ejecuta una vez por semana (o a mano). Guarda datos/estaticos/recetas.json
con los nombres en español.
"""

from __future__ import annotations

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

    salida.parent.mkdir(parents=True, exist_ok=True)
    datos = {"profesiones": profesiones,
             "recetas": {str(k): v for k, v in sorted(recetas_por_id.items())},
             "items": {str(k): v for k, v in sorted(items.items())}}
    salida.write_text(json.dumps(datos, ensure_ascii=False, separators=(",", ":")), "utf-8")
    print(f"Guardado {salida} ({salida.stat().st_size // 1024} KB)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
