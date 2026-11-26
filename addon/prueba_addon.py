"""Prueba de humo del addon en Lua 5.1 (la versión de WoW) con la API del juego simulada.

Ejecutar desde la raíz del repositorio: python addon/prueba_addon.py
Necesita: pip install lupa
"""

import sys
from pathlib import Path

from lupa import lua51

RAIZ = Path(__file__).resolve().parent / "ForeverSubastas"

STUBS = r"""
local function mock(nombre)
  local m = { _nombre = nombre, _shown = false, _scripts = {}, _texto = nil }
  return setmetatable(m, { __index = function(t, k)
    if k == "IsShown" then return function(self) return self._shown end end
    if k == "Show" then return function(self) self._shown = true; if self._scripts.OnShow then self._scripts.OnShow(self) end end end
    if k == "Hide" then return function(self) self._shown = false end end
    if k == "SetScript" then return function(self, ev, fn) self._scripts[ev] = fn end end
    if k == "GetScript" then return function(self, ev) return self._scripts[ev] end end
    if k == "SetText" then return function(self, x) self._texto = x end end
    if k == "GetText" then return function(self) return self._texto end end
    if k == "CreateFontString" or k == "CreateTexture" then return function() return mock(k) end end
    return function() end
  end })
end
CreateFrame = function(tipo, nombre, padre, plantilla)
  local f = mock(nombre or tipo)
  if nombre then _G[nombre] = f end
  return f
end
UIParent = mock("UIParent")
UISpecialFrames = {}
SlashCmdList = {}
LINEAS = {}
local tt = mock("GameTooltip")
tt.AddLine = function(self, a) table.insert(LINEAS, tostring(a)) end
tt.AddDoubleLine = function(self, a, b) table.insert(LINEAS, tostring(a) .. " | " .. tostring(b)) end
tt.GetItem = function(self) return "x", "item:2447" end
GameTooltip = tt
DEFAULT_CHAT_FRAME = { AddMessage = function(self, m) print("CHAT: " .. m) end }
UnitName = function() return "Suci Va" end
GetRealmName = function() return "93" end
time = os.time
GetItemInfoInstant = function(link) return tonumber(link:match("item:(%d+)")) end
GetItemInfo = function(id) return nil end
C_Item = { GetItemNameByID = function(id) return nil end }
C_CurrencyInfo = { GetCoinTextureString = function(c) return c .. "c" end }
GetProfessions = function() return 1, 2, nil, 4, 5, 6 end
local PROFS = { [1] = {"Alquimia", 171, 180}, [2] = {"Herboristería", 182, 200}, [4] = {"Pesca", 356, 120},
                [5] = {"Cocina", 185, 150}, [6] = {"Primeros auxilios", 129, 225} }
GetProfessionInfo = function(i) local p = PROFS[i]; return p[1], 0, p[3], 300, 0, 0, p[2] end
TOOLTIP_CB = nil
TooltipDataProcessor = { AddTooltipPostCall = function(tipo, fn) TOOLTIP_CB = fn end }
Enum = { TooltipDataType = { Item = 0 } }
C_TradeSkillUI = {
  GetAllRecipeIDs = function() return { 2330, 2331 } end,
  GetRecipeInfo = function(id) return { learned = id == 2330, name = id == 2330 and "Poción de curación menor" or "Otra" } end,
  GetRecipeOutputItemData = function(id) return { itemID = id == 2330 and 118 or 999 } end,
  GetBaseProfessionInfo = function() return { professionID = 171 } end,
}
ProfessionsFrame = mock("ProfessionsFrame")
"""


def main() -> int:
    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(STUBS)
    for nombre in ("Datos.lua", "Nucleo.lua"):
        codigo = (RAIZ / nombre).read_text("utf-8")
        lua.execute(codigo)
    g = lua.globals()
    datos = g.ForeverSubastasDatos
    eventos_script = None
    # Lanzar PLAYER_LOGIN y TRADE_SKILL_SHOW sobre el marco de eventos.
    lua.execute("""
      for k, v in pairs(_G) do end
    """)
    lua.execute("""
      -- Buscar el marco de eventos: es el que tiene OnEvent.
      EVENTOS = nil
    """)
    # El marco de eventos se crea sin nombre; lo localizamos reemplazando CreateFrame antes de cargar.
    lua2 = lua51.LuaRuntime(unpack_returned_tuples=True)
    lua2.execute(STUBS)
    lua2.execute("""
      local original = CreateFrame
      MARCOS = {}
      CreateFrame = function(...) local f = original(...); table.insert(MARCOS, f); return f end
    """)
    for nombre in ("Datos.lua", "Nucleo.lua"):
        lua2.execute((RAIZ / nombre).read_text("utf-8"))
    lua2.execute("""
      local ev
      for _, f in ipairs(MARCOS) do if f._scripts.OnEvent then ev = f end end
      ev._scripts.OnEvent(ev, "PLAYER_LOGIN")
      ev._scripts.OnEvent(ev, "TRADE_SKILL_SHOW")
      -- Tooltip de un objeto con datos
      TOOLTIP_CB(GameTooltip, { id = 2447 })
      -- Ventana
      SlashCmdList["FOREVERSUBASTAS"]("")
      local v = ForeverSubastasVentana
      assert(v and v:IsShown(), "la ventana no se muestra")
      FILAS_VISIBLES = 0
      for _, fila in ipairs(v.filas) do if fila._shown then FILAS_VISIBLES = FILAS_VISIBLES + 1 end end
      INFO = v.info._texto
      PIE = v.pie._texto
      -- Cambiar filtros
      v.botonVenta._scripts.OnClick(v.botonVenta, "LeftButton")
      v.botonProf._scripts.OnClick(v.botonProf, "LeftButton")
      v.botonOrden._scripts.OnClick(v.botonOrden, "LeftButton")
      v._scripts.OnMouseWheel(v, -1)
      FILAS_VISIBLES2 = 0
      for _, fila in ipairs(v.filas) do if fila._shown then FILAS_VISIBLES2 = FILAS_VISIBLES2 + 1 end end
      -- Tooltip de una fila
      if v.filas[1].dato then v.filas[1]._scripts.OnEnter(v.filas[1]) end
      PRIMERA = v.filas[1].nombre._texto
      local pj = ForeverSubastas.Personaje()
      CONOCE_118 = pj.conocidas[118] and true or false
      PROF_171 = pj.profs[171]
      SlashCmdList["FOREVERSUBASTAS"]("ayuda")
    """)
    g = lua2.globals()
    lineas = list(g.LINEAS.values())
    print("Líneas de tooltip:")
    for l in lineas[:40]:
        print("   ", l)
    print("Filas visibles:", g.FILAS_VISIBLES, "->", g.FILAS_VISIBLES2)
    print("Info:", g.INFO)
    print("Pie:", g.PIE)
    print("Primera fila tras filtros:", g.PRIMERA)
    assert g.CONOCE_118 is True, "no registró la receta conocida"
    assert g.PROF_171 == 180, "no registró la profesión"
    assert any("Subasta Alianza JcJ" in l for l in lineas), "el tooltip no añade datos"
    print("OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
