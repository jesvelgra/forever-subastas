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
  local m = { _nombre = nombre, _shown = false, _scripts = {}, _texto = nil, _enabled = true }
  return setmetatable(m, { __index = function(t, k)
    if k == "IsShown" then return function(self) return self._shown end end
    if k == "Show" then return function(self) self._shown = true; if self._scripts.OnShow then self._scripts.OnShow(self) end end end
    if k == "Hide" then return function(self) self._shown = false end end
    if k == "SetScript" then return function(self, ev, fn) self._scripts[ev] = fn end end
    if k == "GetScript" then return function(self, ev) return self._scripts[ev] end end
    if k == "SetText" then return function(self, x) self._texto = x end end
    if k == "GetText" then return function(self) return self._texto end end
    if k == "SetEnabled" then return function(self, x) self._enabled = x end end
    if k == "CreateFontString" or k == "CreateTexture" then return function() return mock(k) end end
    return function() end
  end })
end
MOCK = mock
MARCOS = {}
CreateFrame = function(tipo, nombre, padre, plantilla)
  local f = mock(nombre or tipo)
  if nombre then _G[nombre] = f end
  table.insert(MARCOS, f)
  return f
end
UIParent = mock("UIParent")
UISpecialFrames = {}
SlashCmdList = {}
LINEAS = {}
CHAT = {}
local tt = mock("GameTooltip")
tt.AddLine = function(self, a) table.insert(LINEAS, tostring(a)) end
tt.AddDoubleLine = function(self, a, b) table.insert(LINEAS, tostring(a) .. " | " .. tostring(b)) end
tt.GetItem = function(self) return "x", "item:2447" end
GameTooltip = tt
DEFAULT_CHAT_FRAME = { AddMessage = function(self, m) table.insert(CHAT, m); print("CHAT: " .. m) end }
UnitName = function() return "Suci Va" end
GetRealmName = function() return "93" end
time = os.time
date = os.date
GetMoney = function() return 1234567 end
GetItemInfoInstant = function(x) if type(x) == "string" then return tonumber(x:match("item:(%d+)")) end end
GetItemInfo = function(id) if id == 2447 then return "Flor de paz", nil, 1, 5, 0, "x", "y", 20, "", 0, 10 end end
C_Item = { GetItemNameByID = function(id) return nil end, GetItemCount = function(id) return id == 3371 and 2 or 0 end,
           GetItemID = function(loc) return loc.id end }
C_CurrencyInfo = { GetCoinTextureString = function(c) return c .. "c" end }
GetProfessions = function() return 1, 2, nil, 4, 5, 6 end
local PROFS = { [1] = {"Alquimia", 171, 180}, [2] = {"Herboristería", 182, 200}, [4] = {"Pesca", 356, 120},
                [5] = {"Cocina", 185, 150}, [6] = {"Primeros auxilios", 129, 225} }
GetProfessionInfo = function(i) local p = PROFS[i]; return p[1], 0, p[3], 300, 0, 0, p[2] end
TOOLTIP_CB = nil
TooltipDataProcessor = { AddTooltipPostCall = function(tipo, fn) TOOLTIP_CB = fn end }
Enum = { TooltipDataType = { Item = 0 } }
C_TradeSkillUI = {
  GetAllRecipeIDs = function() return { 2330, 2331, 2332 } end,
  GetRecipeInfo = function(id)
    if id == 2330 then return { learned = true, name = "Poción de curación menor", relativeDifficulty = 3 } end
    if id == 2331 then return { learned = true, name = "Elixir de fuerza menor", relativeDifficulty = 1, maxTrivialLevel = 200 } end
    return { learned = false, name = "Poción menor de maná", relativeDifficulty = 0 }
  end,
  GetRecipeOutputItemData = function(id) return { itemID = ({ [2330] = 118, [2331] = 2454, [2332] = 2455 })[id] } end,
  GetBaseProfessionInfo = function() return { professionID = 171, skillLevel = 180, maxSkillLevel = 225 } end,
  GetRecipeRequirements = function(id) if id == 2331 then return { { name = "Rueca", met = false } } end return {} end,
  GetRecipeSourceText = function(id) return "|cFFFFD200Instructor|r|nRequiere Alquimia (150)" end,
}
ProfessionsFrame = mock("ProfessionsFrame")
C_Container = {
  GetContainerNumSlots = function(b) return b == 0 and 3 or 0 end,
  GetContainerItemInfo = function(b, s)
    if s == 1 then return { itemID = 2447, stackCount = 20 } end
    if s == 2 then return { itemID = 118, stackCount = 5 } end
    if s == 3 then return { itemID = 6948, stackCount = 1, isBound = true } end
  end,
}
-- Subasta y ganchos
HOOKS = {}
hooksecurefunc = function(t, nombre, fn) HOOKS[nombre] = fn end
C_AuctionHouse = { ConfirmCommoditiesPurchase = function() end, PostCommodity = function() end, PostItem = function() end }
-- Correo
GetInboxNumItems = function() return 2 end
GetInboxHeaderInfo = function(i) return nil, nil, "Casa de subastas", "x", 0, 0, 29.5 end
GetInboxInvoiceInfo = function(i)
  if i == 1 then return "seller", "Flor de paz", "Comprador", 4000, 4000, 100, 200, 0, 0, 20 end
  return "buyer", "Marregal", "Vendedor", 900, 900, 0, 0, 0, 0, 3
end
-- Ventanas emergentes
StaticPopupDialogs = {}
POPUP = nil
StaticPopup_Show = function(nombre, a, b, data)
  local d = StaticPopupDialogs[nombre]
  local caja = MOCK("caja")
  local popup = { data = data, editBox = caja }
  d.OnShow(popup)
  caja._texto = "3"
  d.OnAccept(popup, data)
  POPUP = nombre
end
-- QuestieDB
ItemDB = {
  GetAllIds = function() return { 9001, 9002 } end,
  class = function(id) return 9 end,
  teachesSpell = function(id) return id == 9001 and 2332 or nil end,
  vendors = function(id) return id == 9001 and { 500, 501 } or nil end,
  npcDrops = function(id) return nil end,
  questRewards = function(id) return nil end,
}
NpcDB = {
  name = function(id) return id == 500 and "Alquimista Mallory" or "Vendedor de la Horda" end,
  spawns = function(id) return { [1519] = { { 50.2, 60.7 } } } end,
  zoneID = function(id) return 1519 end,
  friendlyToFaction = function(id) return id == 500 and "AH" or "H" end,
}
QuestDB = { name = function(id) return "Una misión" end }
LibQuestieDB = { EraToForever = function(a, x, y) return x + 1, y + 1 end,
  Support = { Get = function() return { private = { areaIdToUiMapId = { [1519] = 84 } } } end } }
UnitFactionGroup = function() return "Alliance" end
C_Map = { GetAreaInfo = function(a) return "Ventormenta" end, SetUserWaypoint = function() WAYPOINT = true end }
C_SuperTrack = { SetSuperTrackedUserWaypoint = function() end }
UiMapPoint = { CreateFromCoordinates = function() return {} end }
SHIFT = false
IsShiftKeyDown = function() return SHIFT end
-- Auctionator
LISTA_AUCTIONATOR = nil
Auctionator = { API = { v1 = {
  ConvertToSearchString = function(caller, t) return '"' .. t.searchString .. '";;;;;;;;;;;#;;' .. (t.quantity or "") end,
  CreateShoppingList = function(caller, nombre, cadenas) LISTA_AUCTIONATOR = { nombre = nombre, cadenas = cadenas } end,
} } }
"""

PRUEBA = r"""
local ev
for _, f in ipairs(MARCOS) do if f._scripts.OnEvent then ev = f end end
ev._scripts.OnEvent(ev, "PLAYER_LOGIN")
ev._scripts.OnEvent(ev, "TRADE_SKILL_SHOW")

-- Tooltips
TOOLTIP_CB(GameTooltip, { id = 2447 })
TOOLTIP_CB(GameTooltip, { id = 118 })

-- Pestaña Qué fabricar
SlashCmdList["FOREVERSUBASTAS"]("")
local v = ForeverSubastasVentana
assert(v and v:IsShown(), "la ventana no se muestra")
local function visibles() local n = 0; for _, f in ipairs(v.filas) do if f._shown then n = n + 1 end end; return n end
FILAS_FABRICAR = visibles()
v.botonVenta._scripts.OnClick(v.botonVenta, "LeftButton")
v.botonProf._scripts.OnClick(v.botonProf, "LeftButton")
v.botonOrden._scripts.OnClick(v.botonOrden, "LeftButton")
v._scripts.OnMouseWheel(v, -1)
if v.filas[1].dato then v.filas[1]._scripts.OnEnter(v.filas[1]) end
-- Clic en la primera receta: lista de la compra
v.filas[1]._scripts.OnClick(v.filas[1], "LeftButton")

-- Pestaña Subir profesión
v.pestanas.subir._scripts.OnClick(v.pestanas.subir)
FILAS_SUBIR = visibles()
SUBIR_1 = v.filas[1].c[1]._texto .. " | " .. tostring(v.filas[1].c[2]._texto) .. " | " .. tostring(v.filas[1].c[5]._texto)
INFO_SUBIR = v.info._texto
v.filas[1]._scripts.OnEnter(v.filas[1])
v.filas[1]._scripts.OnClick(v.filas[1], "LeftButton")

-- Instructor
GetNumTrainerServices = function() return 2 end
GetTrainerServiceInfo = function(i) return i == 1 and "Poción menor de maná" or "Elixir de defensa", nil, "available" end
GetTrainerServiceSkillReq = function(i) return "Alquimia", i == 1 and 25 or 250, true end
GetTrainerServiceCost = function(i) return 500 end
UnitName = function(u) if u == "npc" then return "Lilyssia Nightbreeze" end return "Suci Va" end
GetZoneText = function() return "Ventormenta" end
GetSubZoneText = function() return "Distrito de los Magos" end
ev._scripts.OnEvent(ev, "TRAINER_SHOW")
v.pestanas.subir._scripts.OnClick(v.pestanas.subir)
SUBIR_APRENDER = v.filas[1].c[7]._texto .. " / " .. tostring(v.filas[2].c[7]._texto)
v.filas[2]._scripts.OnEnter(v.filas[2])
SHIFT = true
v.filas[2]._scripts.OnClick(v.filas[2], "LeftButton")
SHIFT = false
-- Cambio de color de la receta que se está subiendo (amarilla -> verde)
v.filas[1]._scripts.OnClick(v.filas[1], "LeftButton")
local viejo = C_TradeSkillUI.GetRecipeInfo
C_TradeSkillUI.GetRecipeInfo = function(id)
  local i = viejo(id); if id == 2331 then i.relativeDifficulty = 2 end; return i
end
ev._scripts.OnEvent(ev, "TRADE_SKILL_LIST_UPDATE")
C_TradeSkillUI.GetRecipeInfo = viejo
UnitName = function(u) return "Suci Va" end

-- Pestaña Qué vender
v.pestanas.vender._scripts.OnClick(v.pestanas.vender)
FILAS_VENDER = visibles()
VENDER_1 = v.filas[1].c[1]._texto .. " | " .. tostring(v.filas[1].c[3]._texto) .. " | " .. tostring(v.filas[1].c[7]._texto)
INFO_VENDER = v.info._texto

-- Operaciones: correo, compra de bienes y publicación
ev._scripts.OnEvent(ev, "MAIL_INBOX_UPDATE")
ev._scripts.OnEvent(ev, "MAIL_INBOX_UPDATE")   -- la segunda vez no debe duplicar
ev._scripts.OnEvent(ev, "COMMODITY_PRICE_UPDATED", 300, 1500)
HOOKS.ConfirmCommoditiesPurchase(2447, 5)
ev._scripts.OnEvent(ev, "COMMODITY_PURCHASE_SUCCEEDED")
HOOKS.PostCommodity({ id = 2447 }, 1, 10, 250)
v.pestanas.cuentas._scripts.OnClick(v.pestanas.cuentas)
FILAS_CUENTAS = visibles()
INFO_CUENTAS = v.info._texto
CUENTAS_1 = v.filas[1].c[1]._texto .. " | " .. tostring(v.filas[1].c[2]._texto) .. " | " .. tostring(v.filas[1].c[6]._texto)
NUM_OPS = #ForeverSubastas.Cuentas().ops

v.pestanas.subir._scripts.OnClick(v.pestanas.subir)
v.botonSubirProf._scripts.OnClick(v.botonSubirProf)
local pj = ForeverSubastas.Personaje()
CONOCE_118 = pj.conocidas[118] and true or false
PROF_171 = pj.profs[171]
SlashCmdList["FOREVERSUBASTAS"]("ayuda")
"""


def main() -> int:
    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(STUBS)
    for nombre in ("Datos.lua", "Nucleo.lua"):
        lua.execute((RAIZ / nombre).read_text("utf-8"))
    lua.execute(PRUEBA)
    g = lua.globals()
    lineas = list(g.LINEAS.values())
    print("Líneas de tooltip:")
    for l in lineas[:45]:
        print("   ", l)
    print("Filas en Qué fabricar:", g.FILAS_FABRICAR)
    if g.LISTA_AUCTIONATOR:
        print("Lista Auctionator:", g.LISTA_AUCTIONATOR.nombre, list(g.LISTA_AUCTIONATOR.cadenas.values()))
    print("Subir profesión:", g.FILAS_SUBIR, "filas ·", g.SUBIR_1)
    print("   ", g.INFO_SUBIR)
    print("    Aprender:", g.SUBIR_APRENDER)
    print("Qué vender:", g.FILAS_VENDER, "filas ·", g.VENDER_1)
    print("   ", g.INFO_VENDER)
    print("Mis cuentas:", g.FILAS_CUENTAS, "filas ·", g.CUENTAS_1)
    print("   ", g.INFO_CUENTAS)
    print("Operaciones registradas:", g.NUM_OPS)
    assert g.CONOCE_118 is True, "no registró la receta conocida"
    assert g.PROF_171 == 180, "no registró la profesión"
    assert any("Subasta Alianza JcJ" in l for l in lineas), "el tooltip no añade datos"
    assert any("Si lo fabricas" in l for l in lineas), "el tooltip no muestra el beneficio de fabricar"
    assert any("Tendencia" in l for l in lineas), "el tooltip no muestra la tendencia"
    assert any("Para vender" in l for l in lineas), "el tooltip no muestra el consejo de venta"
    assert g.POPUP == "FOREVERSUBASTAS_LISTA", "no se abrió la ventana de la lista de la compra"
    assert g.FILAS_SUBIR == 2, "Subir profesión debería listar las 2 recetas naranja/amarilla (la gris no)"
    assert any("Coste neto por punto" in l for l in lineas), "falta el coste por punto en el tooltip"
    assert any("Cantidad sugerida" in l for l in lineas), "falta la cantidad sugerida"
    assert any("Necesitas | Rueca" in l for l in lineas), "falta la herramienta necesaria"
    assert any("Instructor | Lilyssia" in l for l in lineas), "falta dónde se aprende"
    assert any("Lo vende | Alquimista Mallory (Ventormenta 51, 62)" in l for l in lineas), "falta el vendedor del patrón"
    assert not any("Vendedor de la Horda" in l for l in lineas), "no debe mostrar vendedores de la Horda"
    assert g.WAYPOINT is True, "no marcó el mapa con mayúsculas + clic"
    chat = list(g.CHAT.values())
    assert any("ya está" in m and "verde" in m for m in chat), "no avisó del cambio a verde"
    assert g.FILAS_VENDER == 2, "Qué vender debería listar 2 objetos (el ligado no)"
    assert g.NUM_OPS == 4, f"deberían registrarse 4 operaciones (venta, compra correo, compra bienes, publicación), hay {g.NUM_OPS}"
    print("OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
