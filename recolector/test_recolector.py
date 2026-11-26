"""Pruebas del recolector con datos simulados (no necesitan conexión).

Ejecutar: python -m unittest discover -s recolector
"""

import csv
import gzip
import os
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest import mock

import recolector as r

HIERBA, POCION, CAPA = 2447, 929, 4316


def c(id_, item, cant, precio, tl="VERY_LONG"):
    return {"id": id_, "item": {"id": item}, "quantity": cant, "unit_price": precio, "time_left": tl}


def i(id_, item, buyout, tl="VERY_LONG", cant=1, bid=None):
    d = {"id": id_, "item": {"id": item, "bonus_lists": [1]}, "quantity": cant, "time_left": tl}
    if buyout is not None:
        d["buyout"] = buyout
    if bid is not None:
        d["bid"] = bid
    return d


class PruebasCalculo(unittest.TestCase):
    def test_normalizar_ignora_solo_puja(self):
        datos = r.normalizar([i(1, CAPA, 5000), i(2, CAPA, None, bid=100)], "i")
        self.assertEqual(list(datos), [1])
        self.assertEqual(datos[1], (CAPA, 1, 5000, "VERY_LONG"))

    def test_resumir_percentiles_por_unidades(self):
        actual = r.normalizar([c(1, HIERBA, 10, 100), c(2, HIERBA, 80, 120), c(3, HIERBA, 10, 500)], "c")
        res = r.resumir(actual)[HIERBA]
        self.assertEqual(res["n"], 3)
        self.assertEqual(res["cant"], 100)
        self.assertEqual(res["min"], 100)
        self.assertEqual(res["p10"], 100)
        self.assertEqual(res["p50"], 120)

    def test_compra_parcial_es_venta_segura(self):
        ant = r.normalizar([c(1, HIERBA, 20, 100)], "c")
        act = r.normalizar([c(1, HIERBA, 5, 100)], "c")
        m = r.estimar_movimientos(ant, act, 1.0)[HIERBA]
        self.assertEqual(m["vend_seg"], 15)
        self.assertEqual(m["valor_vend"], 1500)

    def test_desaparece_la_mas_barata_es_venta_probable(self):
        ant = r.normalizar([c(1, HIERBA, 20, 90), c(2, HIERBA, 20, 100)], "c")
        act = r.normalizar([c(2, HIERBA, 20, 100)], "c")
        m = r.estimar_movimientos(ant, act, 1.0)[HIERBA]
        self.assertEqual(m["vend_prob"], 20)
        self.assertEqual(m["retiradas"], 0)

    def test_desaparece_una_cara_es_retirada(self):
        ant = r.normalizar([c(1, HIERBA, 20, 90), c(2, HIERBA, 20, 300)], "c")
        act = r.normalizar([c(1, HIERBA, 20, 90), c(3, HIERBA, 20, 95)], "c")
        m = r.estimar_movimientos(ant, act, 1.0)[HIERBA]
        self.assertEqual(m["retiradas"], 20)
        self.assertEqual(m["vend_prob"], 0)
        self.assertEqual(m["nuevas"], 20)

    def test_compra_parcial_eleva_el_umbral(self):
        # Se compró parte del lote a 150, así que el de 120 que desaparece se vendió.
        ant = r.normalizar([c(1, HIERBA, 10, 120), c(2, HIERBA, 10, 150)], "c")
        act = r.normalizar([c(2, HIERBA, 4, 150), c(3, HIERBA, 10, 140)], "c")
        m = r.estimar_movimientos(ant, act, 1.0)[HIERBA]
        self.assertEqual(m["vend_seg"], 6)
        self.assertEqual(m["vend_prob"], 10)

    def test_pudo_caducar(self):
        ant = r.normalizar([c(1, HIERBA, 10, 100, tl="MEDIUM"), c(2, HIERBA, 10, 100, tl="SHORT")], "c")
        act = r.normalizar([c(3, HIERBA, 10, 200)], "c")
        m = r.estimar_movimientos(ant, act, 1.0)[HIERBA]
        self.assertEqual(m["caducadas"], 10)   # SHORT (≤0,5 h) pudo caducar en 1 h
        self.assertEqual(m["vend_prob"], 10)   # MEDIUM puede durar hasta 2 h: no caducó
        m2 = r.estimar_movimientos(ant, act, 2.5)[HIERBA]
        self.assertEqual(m2["caducadas"], 20)

    def test_se_agota_el_objeto(self):
        ant = r.normalizar([i(1, CAPA, 5000)], "i")
        m = r.estimar_movimientos(ant, {}, 1.0)[CAPA]
        self.assertEqual(m["vend_prob"], 1)
        self.assertEqual(m["valor_vend"], 5000)


class PruebasTramos(unittest.TestCase):
    def test_tramo(self):
        self.assertEqual(r.tramo(0.9), 0)
        self.assertEqual(r.tramo(1.0), 1)
        self.assertEqual(r.tramo(1.07), 3)
        self.assertEqual(r.tramo(3.0), len(r.TRAMOS))

    def test_ventas_y_caducadas_por_tramo(self):
        # Subasta 1 aparece al precio de referencia (ratio 1.0) y se vende entera;
        # subasta 2 aparece un 40 % más cara y caduca.
        ant = {1: (HIERBA, 10, 100, "LONG", 1.0), 2: (HIERBA, 5, 140, "SHORT", 1.4)}
        act = {3: (HIERBA, 10, 100, "VERY_LONG", 1.0)}
        tramos = {}
        r.estimar_movimientos(ant, act, 1.0, tramos)
        self.assertEqual(tramos[(HIERBA, r.tramo(1.0))], [10, 0])
        self.assertEqual(tramos[(HIERBA, r.tramo(1.4))], [0, 5])


class PruebasFicheros(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dd = Path(self.tmp.name) / "datos"
        self.de = Path(self.tmp.name) / "estado"

    def tearDown(self):
        self.tmp.cleanup()

    def leer(self, ruta):
        with gzip.open(ruta, "rt", encoding="utf-8") as f:
            return list(csv.DictReader(f))

    def test_dos_descargas_seguidas(self):
        t0 = datetime(2026, 11, 26, 11, 5, tzinfo=timezone.utc)
        r1 = r.procesar_feed(ts=t0, casa=113, tipo="c",
                             subastas_api=[c(1, HIERBA, 20, 100), c(2, POCION, 5, 900)],
                             dir_datos=self.dd, dir_estado=self.de)
        self.assertFalse(r1["saltado"])
        self.assertIsNone(r1["horas"])

        # Misma descarga otra vez: se salta.
        r_rep = r.procesar_feed(ts=t0, casa=113, tipo="c", subastas_api=[c(1, HIERBA, 20, 100)],
                                dir_datos=self.dd, dir_estado=self.de)
        self.assertTrue(r_rep["saltado"])

        t1 = t0 + timedelta(hours=1)
        r2 = r.procesar_feed(ts=t1, casa=113, tipo="c",
                             subastas_api=[c(1, HIERBA, 8, 100)],
                             dir_datos=self.dd, dir_estado=self.de)
        self.assertEqual(r2["vendidas"], 12 + 5)
        filas = self.leer(self.dd / "2026/11/26/20261126T1205_casa113_c.csv.gz")
        por_item = {int(f["item"]): f for f in filas}
        self.assertEqual(por_item[HIERBA]["vend_seg"], "12")
        self.assertEqual(por_item[POCION]["n"], "0")          # agotada, pero se registra la venta
        self.assertEqual(por_item[POCION]["vend_prob"], "5")
        self.assertEqual(por_item[POCION]["horas"], "1.0")

    def test_hueco_largo_no_estima_ventas(self):
        t0 = datetime(2026, 11, 26, 1, 0, tzinfo=timezone.utc)
        r.procesar_feed(ts=t0, casa=1, tipo="c", subastas_api=[c(1, HIERBA, 20, 100)],
                        dir_datos=self.dd, dir_estado=self.de)
        res = r.procesar_feed(ts=t0 + timedelta(hours=10), casa=1, tipo="c",
                              subastas_api=[c(2, HIERBA, 20, 100)],
                              dir_datos=self.dd, dir_estado=self.de)
        self.assertIsNone(res["horas"])
        self.assertEqual(res["vendidas"], 0)


class PruebaCompleta(unittest.TestCase):
    """Simula la API entera y ejecuta main() dos veces."""

    def test_main_con_api_simulada(self):
        estado = {"lm": "Thu, 26 Nov 2026 11:05:00 GMT", "hierba": 20}

        def falsa(url, cabeceras=None, datos=None, intentos=4):
            cab = {"Last-Modified": estado["lm"]}
            if "oauth.battle.net" in url:
                return {"access_token": "x"}, {}
            ruta = url.split("api.blizzard.com", 1)[1].split("?", 1)[0]
            if ruta == "/data/wow/ruleset/index":
                return {"rulesets": [{"id": 1, "name": "PvP"}, {"id": 2, "name": "Normal"}]}, {}
            if ruta.endswith("/auctions/"):
                return {"auctions": [{"id": 113, "name": "Alliance Auction House"},
                                     {"id": 114, "name": "Horde Auction House"},
                                     {"id": 112, "name": "Alliance Auction House"}]}, {}
            if ruta == "/data/wow/ruleset/1/auctions/113":
                return {"id": 113, "auctions": [i(50, CAPA, 7000)]}, cab
            if ruta == "/data/wow/ruleset/1/auctions/113/commodities":
                return {"auctions": [c(1, HIERBA, estado["hierba"], 100)]}, cab
            if ruta == "/data/wow/ruleset/1/auctions/112":
                return {"id": 112}, cab        # casa vacía, sin campo auctions
            if ruta == "/data/wow/ruleset/1/auctions/112/commodities":
                raise r.ErrorApi(404, url)
            raise AssertionError(f"ruta inesperada {ruta}")

        with tempfile.TemporaryDirectory() as tmp, \
                mock.patch.object(r, "_peticion", side_effect=falsa), \
                mock.patch.dict(os.environ, {"BLIZZARD_CLIENT_ID": "a", "BLIZZARD_CLIENT_SECRET": "b",
                                             "DIR_DATOS": f"{tmp}/datos", "DIR_ESTADO": f"{tmp}/estado"}):
            self.assertEqual(r.main(), 0)
            estado.update(lm="Thu, 26 Nov 2026 12:05:00 GMT", hierba=3)
            self.assertEqual(r.main(), 0)
            ficheros = sorted(p.name for p in Path(tmp, "datos").rglob("*.csv.gz") if "tramos" not in p.parts)
            tramos = list(Path(tmp, "datos", "tramos").rglob("*.csv.gz"))
            self.assertEqual(len(tramos), 1)
            self.assertEqual(ficheros, [
                "20261126T1105_casa113_c.csv.gz", "20261126T1105_casa113_i.csv.gz",
                "20261126T1205_casa113_c.csv.gz", "20261126T1205_casa113_i.csv.gz"])
            self.assertTrue(Path(tmp, "datos", "casas.json").exists())


if __name__ == "__main__":
    unittest.main()
