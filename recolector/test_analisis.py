"""Pruebas del análisis con un historial simulado."""

import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

import analisis as a
import recolector as r

HIERBA, POCION, VIAL = 2447, 118, 3371


def simular(dir_datos: Path, dias: int, inicio: datetime):
    """Hierba: más barata a las 5 h de Madrid y más cara a las 21 h; se venden 2/h (más por la tarde)."""
    filas_por_ts = []
    for h in range(dias * 24):
        ts = inicio + timedelta(hours=h)
        hora_local = ts.astimezone(a.ZONA).hour
        precio = 100
        if hora_local == 5:
            precio = 80
        elif hora_local == 21:
            precio = 130
        vendidas = 4 if 18 <= hora_local <= 22 else 2
        fila_h = {"ts": ts.strftime("%Y-%m-%dT%H:%M:%SZ"), "casa": 110, "tipo": "c", "item": HIERBA,
                  "n": 10, "cant": 200, "min": precio - 5, "p10": precio, "p25": precio + 5, "p50": precio + 10,
                  "nuevas": vendidas, "vend_seg": vendidas, "vend_prob": 0, "valor_vend": vendidas * 110,
                  "retiradas": 0, "caducadas": 0, "horas": "" if h == 0 else 1.0}
        fila_p = dict(fila_h, item=POCION, min=900, p10=950, p25=1000, p50=1100,
                      vend_seg=1, valor_vend=1000, nuevas=1)
        ruta = dir_datos / ts.strftime("%Y/%m/%d") / f"{ts:%Y%m%dT%H%M}_casa110_c.csv.gz"
        r.escribir_csv(ruta, [fila_h, fila_p])
        filas_por_ts.append(ts)
    return filas_por_ts


class PruebasAnalisis(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dd = Path(self.tmp.name) / "datos"
        self.inicio = datetime(2026, 11, 20, 0, 21, tzinfo=timezone.utc)
        self.tss = simular(self.dd, 5, self.inicio)
        self.ahora = self.tss[-1] + timedelta(minutes=10)
        self.res = a.analizar(self.dd, 110, ahora=self.ahora)

    def tearDown(self):
        self.tmp.cleanup()

    def test_horas_baratas_y_caras(self):
        h = self.res["items"][HIERBA]
        self.assertEqual(h["bh"], 5)
        self.assertEqual(h["sh"], 21)
        self.assertGreater(h["ab"], 10)

    def test_ventas_y_precio_real(self):
        h = self.res["items"][HIERBA]
        # 19 h a 2/h + 5 h a 4/h = 58 al día
        self.assertAlmostEqual(h["vd"], 58, delta=3)
        self.assertEqual(h["pv"], 110)
        self.assertEqual(self.res["items"][POCION]["pv"], 1000)

    def test_precio_compra_24h(self):
        self.assertEqual(self.res["items"][HIERBA]["cmp"], 100)
        self.assertEqual(self.res["items"][HIERBA]["min"], 95)

    def test_recetas_y_lua(self):
        estaticos = {
            "profesiones": [{"id": 171, "nombre": "Alquimia", "niveles": [{"id": 1, "nombre": "Alquimia"}]}],
            "recetas": {"2330": {"prof": 171, "nombre": "Poción de curación menor", "item": POCION, "cant": 1,
                                 "reag": [[HIERBA, 2], [VIAL, 1]]}},
            "items": {str(VIAL): {"n": "Vial vacío", "compra": 20, "lote": 5},
                      str(POCION): {"n": "Poción de curación menor", "venta": 5},
                      str(HIERBA): {"n": "Flor de paz"}},
        }
        vendedor = a.precios_vendedor(estaticos, {})
        self.assertEqual(vendedor[VIAL], 4)
        recetas = a.calcular_recetas(estaticos, self.res["items"], vendedor)
        self.assertEqual(len(recetas), 1)
        rec = recetas[0]
        self.assertEqual(rec["coste"], 2 * 100 + 4)
        self.assertEqual(rec["venta"], 950)          # 1000 menos el 5 % de la subasta
        self.assertEqual(rec["beneficio"], 950 - 204)
        self.assertEqual(rec["donde"], "real")
        ruta = Path(self.tmp.name) / "Datos.lua"
        a.escribir_lua(ruta, self.res, recetas, estaticos)
        texto = ruta.read_text("utf-8")
        self.assertIn("ForeverSubastasDatos = {", texto)
        self.assertIn('"Poción de curación menor"', texto)
        self.assertIn("[171]=\"Alquimia\"", texto)

    def test_mercado_general(self):
        precio_h = self.res["mercado"]["precio_h"]
        self.assertEqual(min(range(24), key=lambda h: precio_h[h] or 9), 5)


class PruebasPrecioRecomendado(unittest.TestCase):
    def test_elige_el_que_mas_cobra_de_media(self):
        # Subir a 1,2x baja la venta del 90 % al 85 %: compensa (1,2*0,85 > 1*0,9).
        curva = [0.92, 0.9, 0.89, 0.88, 0.85, 0.4, 0.2, 0.05]
        precio, ratio, prob = a.precio_recomendado(1000, curva)
        self.assertEqual((precio, ratio, prob), (1200, 1.2, 85))

    def test_sin_curva_no_recomienda(self):
        self.assertEqual(a.precio_recomendado(1000, [None] * 8), (None, None, None))

    def test_curva_del_objeto_se_mezcla_con_la_general(self):
        glob = [0.5] * 8
        por_item = {(HIERBA, 1): [30, 0]}  # todo lo que se puso al precio habitual se vendió
        curva, total = a.curva_item(HIERBA, por_item, glob)
        self.assertEqual(total, 30)
        self.assertAlmostEqual(curva[1], (30 + 10 * 0.5) / 40)
        self.assertEqual(curva[0], 0.5)

    def test_extremo_a_extremo_con_tramos(self):
        with tempfile.TemporaryDirectory() as tmp:
            dd = Path(tmp) / "datos"
            ts = datetime(2026, 11, 26, 11, 21, tzinfo=timezone.utc)
            r.escribir_csv(dd / "2026/11/26/20261126T1121_casa110_c.csv.gz", [{
                "ts": "", "casa": 110, "tipo": "c", "item": HIERBA, "n": 5, "cant": 50, "min": 95, "p10": 100,
                "p25": 110, "p50": 120, "nuevas": 0, "vend_seg": 0, "vend_prob": 0, "valor_vend": 0,
                "retiradas": 0, "caducadas": 0, "horas": ""}])
            filas = []
            for tr, (v, c) in enumerate([(90, 10), (90, 10), (85, 15), (80, 20), (70, 30), (20, 80), (5, 95), (1, 99)]):
                filas.append({"ts": "", "casa": 110, "tipo": "c", "item": HIERBA, "tramo": tr,
                              "vendidas": v, "caducadas": c})
            r.escribir_csv(dd / "tramos/2026/11/26/20261126T1121_casa110_c.csv.gz", filas, r.COLUMNAS_TRAMOS)
            res = a.analizar(dd, 110, ahora=ts + timedelta(minutes=5))
            info = res["items"][HIERBA]
            # 1,0 x 0,90 = 0,90 gana a 1,05 x 0,85 = 0,89 y a 1,1 x 0,8 = 0,88
            self.assertEqual(info["rec"], 100)
            self.assertEqual(info["rec_prob"], 90)
            self.assertEqual(info["curva"][0], 90)
            self.assertEqual(res["mercado"]["curvas"]["c"][1], 90)


class PruebasChollos(unittest.TestCase):
    def test_marca_lo_que_esta_por_debajo_del_vendedor(self):
        with tempfile.TemporaryDirectory() as tmp:
            dd = Path(tmp) / "datos"
            simular(dd, 2, datetime(2026, 11, 20, 0, 21, tzinfo=timezone.utc))
            ahora = datetime(2026, 11, 22, 0, 30, tzinfo=timezone.utc)
            # La hierba se vende al vendedor por 98c y su mínimo va de 75 a 125: chollo casi siempre;
            # la poción (mínimo 900) por 500c: nunca.
            res = a.analizar(dd, 110, ahora=ahora, precio_vendedor={HIERBA: 98, POCION: 500})
            self.assertEqual(res["items"][HIERBA]["vend"], 98)
            self.assertGreater(res["items"][HIERBA]["chollo_pct"], 90)
            self.assertEqual(res["items"][POCION]["chollo_pct"], 0)


class PruebasNivelRequerido(unittest.TestCase):
    def test_no_confunde_el_tramo_con_el_nivel(self):
        self.assertIsNone(a.nivel_requerido({"nivel": 2937}))
        self.assertEqual(a.nivel_requerido({"nivel": 80, "patron": 2601}), 80)
        self.assertEqual(a.nivel_requerido({"nivel": 2948, "patron": 1, "nivel_req": 165}), 165)


class PruebasTendencia(unittest.TestCase):
    def test_tendencia_7d_sube_y_aguanta_dias_raros(self):
        from datetime import date
        hoy = date(2026, 11, 26)
        # Sube un 10 % al día, con un día raro muy barato.
        diaria = {hoy - timedelta(days=k): 100 * 1.1 ** (7 - k) for k in range(8)}
        diaria[hoy - timedelta(days=3)] = 5
        t = a.tendencia_7d(diaria, hoy)
        self.assertAlmostEqual(t, (1.1 ** 7 - 1) * 100, delta=8)

    def test_tendencia_7d_sin_datos(self):
        from datetime import date
        hoy = date(2026, 11, 26)
        self.assertIsNone(a.tendencia_7d({hoy: 100, hoy - timedelta(days=1): 90}, hoy))

    def test_tendencia_24h(self):
        ref = datetime(2026, 11, 26, 12, 0, tzinfo=timezone.utc)
        serie = [(ref - timedelta(hours=h), 120 if h < 6 else 100) for h in range(31)]
        self.assertEqual(a.tendencia_24h(serie), 20.0)

    def test_semilla_da_tendencia_desde_el_primer_dia(self):
        with tempfile.TemporaryDirectory() as tmp:
            dd = Path(tmp) / "datos"
            ts = datetime(2026, 11, 26, 11, 21, tzinfo=timezone.utc)
            r.escribir_csv(dd / "2026/11/26/20261126T1121_casa110_c.csv.gz", [{
                "ts": "", "casa": 110, "tipo": "c", "item": HIERBA, "n": 5, "cant": 50, "min": 200, "p10": 210,
                "p25": 220, "p50": 230, "nuevas": 0, "vend_seg": 0, "vend_prob": 0, "valor_vend": 0,
                "retiradas": 0, "caducadas": 0, "horas": ""}])
            from datetime import date
            semilla = {HIERBA: {date(2026, 11, 19) + timedelta(days=k): 100 + 15 * k for k in range(7)}}
            res = a.analizar(dd, 110, ahora=ts + timedelta(minutes=5), semilla=semilla)
            self.assertGreater(res["items"][HIERBA]["t7"], 50)


if __name__ == "__main__":
    unittest.main()
