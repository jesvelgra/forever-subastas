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
    if k == "SetPoint" then return function(self, ...) self._punto = {...} end end
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
  GetAllRecipeIDs = function() return { 2330, 2331, 2332, 17187, 3330 } end,
  GetRecipeCooldown = function(id) if id == 17187 then return CD_ARCANITA end end,
  GetRecipeInfo = function(id)
    if id == 17187 then return { learned = true, name = "Transmutar: arcanita", relativeDifficulty = 3 } end
    if id == 3330 then return { learned = true, name = "Transmutar: hierro a oro", relativeDifficulty = 3 } end
    if id == 2330 then return { learned = true, name = "Poción de curación menor", relativeDifficulty = 3 } end
    if id == 2331 then return { learned = true, name = "Elixir de fuerza menor", relativeDifficulty = 1, maxTrivialLevel = 200 } end
    return { learned = false, name = "Poción menor de maná", relativeDifficulty = 0 }
  end,
  GetRecipeOutputItemData = function(id) return { itemID = ({ [2330] = 118, [2331] = 2454, [2332] = 2455, [17187] = 12360, [3330] = 3577 })[id] } end,
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
-- Escaneo completo y vendedor
C_Timer = { After = function(_, f) f() end, NewTicker = function(s, f) TICKER = f end }
CD_ARCANITA = 20 * 3600 + 120
C_AuctionHouse.GetNumReplicateItems = function() return 2 end
C_AuctionHouse.GetReplicateItemInfo = function(k)
  if k == 0 then return "Flor de paz", 0, 20, 1, true, 1, 0, 0, 0, 100, 0, false, nil, "x", "x", 0, 2447, true end
  return "Poción", 0, 5, 1, true, 1, 0, 0, 0, 5000, 0, false, nil, "x", "x", 0, 118, true
end
MerchantFrame = MOCK("MerchantFrame")
VENDIDOS = {}
C_Container.UseContainerItem = function(b, s) table.insert(VENDIDOS, s) end
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
-- Escaneo completo de Auctionator: precios en vivo y chollos (Flor de paz a 5c, el vendedor paga 10c)
ev._scripts.OnEvent(ev, "REPLICATE_ITEM_LIST_UPDATE")
LINEAS_ANTES = #LINEAS
TOOLTIP_CB(GameTooltip, { id = 2447 })
v.pestanas.chollos._scripts.OnClick(v.pestanas.chollos)
FILAS_CHOLLOS = visibles()
CHOLLOS_1 = v.filas[1].c[1]._texto .. " | " .. tostring(v.filas[1].c[2]._texto) .. " | " .. tostring(v.filas[1].c[6]._texto)
INFO_CHOLLOS = v.info._texto
LISTA_AUCTIONATOR = nil
v.botonListaChollos._scripts.OnClick(v.botonListaChollos)
LISTA_CHOLLOS = LISTA_AUCTIONATOR and LISTA_AUCTIONATOR.nombre
-- Compra de 5 Flores de paz a 5c: es un chollo
ev._scripts.OnEvent(ev, "COMMODITY_PRICE_UPDATED", 5, 25)
HOOKS.ConfirmCommoditiesPurchase(2447, 5)
ev._scripts.OnEvent(ev, "COMMODITY_PURCHASE_SUCCEEDED")
PENDIENTES_2447 = ForeverSubastas.Cuentas().chollos[2447]
-- En el vendedor: el montón de 20 está mezclado con las tuyas, no se vende
MerchantFrame._shown = true
ForeverSubastas.VenderChollos()
VENDIDOS_MEZCLA = #VENDIDOS
-- Si el montón es solo de chollos (5), sí
C_Container.GetContainerItemInfo = function(b, s) if s == 1 then return { itemID = 2447, stackCount = 5 } end end
ForeverSubastas.VenderChollos()
VENDIDOS_SOLO = #VENDIDOS

-- Botones de la subasta: con pocas pestañas van a su lado; si las pestañas llegan a su zona, bajan
local function hijo(b, t, d)
  local m = MOCK("pestaña"); m._shown = true
  m.GetBottom = function() return b end; m.GetTop = function() return t end; m.GetRight = function() return d end
  return m
end
local HIJOS = { hijo(70, 102, 500), hijo(300, 700, 990) }   -- pestañas de Blizzard y un panel interior
AuctionHouseFrame = {}
AuctionHouseFrame.GetBottom = function() return 100 end
AuctionHouseFrame.GetRight = function() return 1000 end
AuctionHouseFrame.GetChildren = function(self)
  local t = {}
  for _, h in ipairs(HIJOS) do table.insert(t, h) end
  if self.ForeverSubastasBoton then table.insert(t, self.ForeverSubastasBoton) end
  if self.ForeverSubastasBotonChollos then table.insert(t, self.ForeverSubastasBotonChollos) end
  return unpack(t)
end
ev._scripts.OnEvent(ev, "AUCTION_HOUSE_SHOW")
Y_BOTON_SOLO = AuctionHouseFrame.ForeverSubastasBoton._punto[5]
-- Pestañas de Auctionator: cuelgan de un marco intermedio de 10x10 (LibAHTab) y llegan a la zona de los botones
local raiz = hijo(92, 102, 410)
raiz.GetChildren = function() return hijo(68, 102, 560), hijo(68, 102, 780) end
table.insert(HIJOS, raiz)
ev._scripts.OnEvent(ev, "AUCTION_HOUSE_SHOW")
Y_BOTON_AUCTIONATOR = AuctionHouseFrame.ForeverSubastasBoton._punto[5]
ANCLA_CHOLLOS = AuctionHouseFrame.ForeverSubastasBotonChollos._punto[1] .. "/" .. AuctionHouseFrame.ForeverSubastasBotonChollos._punto[3]

-- Enfriamientos: la arcanita está en enfriamiento (20 h) y se ve en Qué fabricar, en la línea de arriba y con /fsub cd
local pjc = ForeverSubastas.Personaje()
CD_FIN_OK = pjc.cd[12360] and (pjc.cd[12360].fin - time()) > 20 * 3600 and pjc.cd[12360].h == 47
CD_ORO = pjc.cd[3577] and pjc.cd[3577].h
v.pestanas.fabricar._scripts.OnClick(v.pestanas.fabricar)
INFO_FABRICAR = v.info._texto
FILA_ARCANITA = nil
for i = 1, 400 do
  ForeverSubastas.Refrescar()
  for _, f in ipairs(v.filas) do
    local t = f.c[1]._texto or ""
    if t:find("Transmutar: arcanita", 1, true) then FILA_ARCANITA = t end
  end
  if FILA_ARCANITA then break end
end
GameTooltip.SetOwner = function() end
for _, f in ipairs(v.filas) do
  if (f.c[1]._texto or ""):find("Transmutar: arcanita", 1, true) then
    local antes = #LINEAS
    f._scripts.OnEnter(f)
    for k = antes + 1, #LINEAS do
      if LINEAS[k]:find("por día de enfriamiento", 1, true) then TOOLTIP_CD = LINEAS[k] end
      if LINEAS[k]:find("Enfriamiento: cada", 1, true) then TOOLTIP_CD2 = LINEAS[k] end
    end
  end
end
CHAT_ANTES = #CHAT
SlashCmdList["FOREVERSUBASTAS"]("cd")
CD_LISTA = CHAT[#CHAT]
-- Queda lista: un único aviso en el chat (y ninguno por la de 1 h)
pjc.cd[12360].fin = time() - 10
AVISOS_1 = ForeverSubastas.AvisarEnfriamientos()
AVISOS_2 = ForeverSubastas.AvisarEnfriamientos()
AVISO_TEXTO = CHAT[#CHAT]
-- Transmuta con la ventana cerrada: vuelve a 47 h
ev._scripts.OnEvent(ev, "UNIT_SPELLCAST_SUCCEEDED", "player", "guid", 17187)
CD_TRAS_LANZAR = math.floor((pjc.cd[12360].fin - time()) / 3600 + 0.5)
-- Al abrir la ventana, el juego manda
CD_ARCANITA = 46 * 3600 + 3500
ev._scripts.OnEvent(ev, "TRADE_SKILL_LIST_UPDATE")
CD_TRAS_LEER = pjc.cd[12360].h
-- Tooltip de la receta en la ventana: enfriamiento y beneficio por día
LINEAS_CD = #LINEAS

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
    print("Chollos:", g.FILAS_CHOLLOS, "filas ·", g.CHOLLOS_1, "·", g.INFO_CHOLLOS)
    print("Lista de chollos:", g.LISTA_CHOLLOS, "· pendientes de vender:", g.PENDIENTES_2447,
          "· vendidos mezclados/solos:", g.VENDIDOS_MEZCLA, g.VENDIDOS_SOLO)
    nuevas = list(g.LINEAS.values())[g.LINEAS_ANTES:]
    print("Tooltip tras escanear:", [l for l in nuevas if "Mínimo" in l or "Chollo" in l])
    print("Botones de la subasta: y =", g.Y_BOTON_SOLO, "sin Auctionator;", g.Y_BOTON_AUCTIONATOR, "con Auctionator;", g.ANCLA_CHOLLOS)
    assert g.Y_BOTON_SOLO == -2, "sin pestañas en su zona, los botones van al lado de las pestañas"
    assert g.Y_BOTON_AUCTIONATOR == -34, "con pestañas en su zona, los botones bajan debajo de ellas"
    assert g.ANCLA_CHOLLOS == "RIGHT/LEFT", "Chollos va a la izquierda de Qué vender"
    print("Enfriamientos:", g.FILA_ARCANITA, "·", g.INFO_FABRICAR)
    print("   /fsub cd:", g.CD_LISTA)
    print("   aviso:", g.AVISOS_1, g.AVISOS_2, g.AVISO_TEXTO, "· tras lanzar:", g.CD_TRAS_LANZAR, "h · tras leer:", g.CD_TRAS_LEER)
    print("   tooltip:", g.TOOLTIP_CD2, "·", g.TOOLTIP_CD)
    assert g.TOOLTIP_CD and g.TOOLTIP_CD2, "el tooltip de la receta no muestra el enfriamiento ni el beneficio por día"
    assert g.CD_FIN_OK, "no guardó el enfriamiento de la arcanita"
    assert g.CD_ORO == 1, "debería apuntar la transmutación de hierro a oro (enfriamiento conocido)"
    assert g.FILA_ARCANITA and "20h" in g.FILA_ARCANITA, "Qué fabricar no muestra el enfriamiento"
    assert "Enfriamientos: arcanita" in g.INFO_FABRICAR, "falta el resumen de enfriamientos"
    assert "Transmutar: arcanita" in g.CD_LISTA and "cada 47 h" in g.CD_LISTA, "/fsub cd no lista el enfriamiento"
    assert g.AVISOS_1 == 1 and g.AVISOS_2 == 0, "el aviso debe salir una sola vez (y no para la de 1 h)"
    assert g.CD_TRAS_LANZAR == 47, "al transmutar debería volver a 47 h"
    assert g.CD_TRAS_LEER == 47, "al leer la ventana justo después debería confirmar 47 h"
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
    assert g.FILAS_CHOLLOS >= 1 and "Tu escaneo" in g.INFO_CHOLLOS, "la pestaña Chollos no usa el escaneo"
    assert g.LISTA_CHOLLOS == "FS Chollos vendedor", "no creó la lista de chollos"
    assert g.PENDIENTES_2447 == 5, "no apuntó la compra como chollo"
    assert g.VENDIDOS_MEZCLA == 0 and g.VENDIDOS_SOLO == 1, "venta al vendedor incorrecta"
    nuevas = list(g.LINEAS.values())[g.LINEAS_ANTES:]
    assert any("tu escaneo" in l for l in nuevas) and any("Chollo" in l for l in nuevas), "el tooltip no usa el escaneo"
    assert g.NUM_OPS >= 4, f"deberían registrarse 4 operaciones (venta, compra correo, compra bienes, publicación), hay {g.NUM_OPS}"
    print("OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
