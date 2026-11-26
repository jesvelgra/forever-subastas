-- Forever Subastas
-- Muestra en el juego lo que calcula el analizador en la nube (forever-subastas):
-- precios, ventas reales, mejores horas y rentabilidad de recetas.

local FS = {}
_G.ForeverSubastas = FS

local D = ForeverSubastasDatos
local GetItemInfo = GetItemInfo or (C_Item and C_Item.GetItemInfo)
local GetItemInfoInstant = GetItemInfoInstant or (C_Item and C_Item.GetItemInfoInstant)

local DIAS = { "lunes", "martes", "miércoles", "jueves", "viernes", "sábado", "domingo" }
local AMARILLO, GRIS, VERDE, ROJO, NARANJA, FIN = "|cffffd100", "|cff9d9d9d", "|cff1eff00", "|cffff4040", "|cffff9933", "|r"

-- Posiciones dentro de D.i[id]
local I_MIN, I_CMP, I_PV, I_VD, I_CANT, I_BH, I_SH, I_AB, I_AS, I_BD, I_SD, I_ADB, I_ADS = 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13
local I_T24, I_T7 = 15, 16
-- Posiciones dentro de cada receta de D.r
local R_PROF, R_NOMBRE, R_ITEM, R_CANT, R_COSTE, R_VENTA, R_BENEF, R_VD, R_DONDE, R_REAG, R_FALTA = 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12

---------------------------------------------------------------------------
-- Utilidades
---------------------------------------------------------------------------

local function Moneda(cobre)
    if cobre == nil then return GRIS .. "?" .. FIN end
    local negativo = cobre < 0
    cobre = math.floor(math.abs(cobre) + 0.5)
    local texto
    if cobre == 0 then
        texto = "0c"
    elseif C_CurrencyInfo and C_CurrencyInfo.GetCoinTextureString then
        texto = C_CurrencyInfo.GetCoinTextureString(cobre)
    elseif GetCoinTextureString then
        texto = GetCoinTextureString(cobre)
    else
        local o, p, c = math.floor(cobre / 10000), math.floor((cobre % 10000) / 100), cobre % 100
        texto = (o > 0 and (o .. "o ") or "") .. ((o > 0 or p > 0) and (p .. "p ") or "") .. c .. "c"
    end
    if negativo then return ROJO .. "-" .. FIN .. texto end
    return texto
end
FS.Moneda = Moneda

local function Hora(h)
    return string.format("%02d-%02d h", h, (h + 1) % 24)
end

local function Ventas(vd)
    if vd == nil then return GRIS .. "midiendo" .. FIN end
    if vd >= 10 then return VERDE .. string.format("%.0f", vd) .. FIN end
    if vd >= 1 then return string.format("%.0f", vd) end
    if vd > 0 then return NARANJA .. string.format("%.1f", vd) .. FIN end
    return ROJO .. "0" .. FIN
end

local function Tendencia(t)
    if t == nil then return nil end
    if math.abs(t) < 3 then return "estable" end
    if t > 0 then return VERDE .. string.format("sube +%.0f%%", t) .. FIN end
    return ROJO .. string.format("baja %.0f%%", t) .. FIN
end
FS.Tendencia = Tendencia

local function HorasDesde(ts)
    if not ts or not time then return nil end
    return (time() - ts) / 3600
end

local function NombreObjeto(id)
    local nombre
    if C_Item and C_Item.GetItemNameByID then
        nombre = C_Item.GetItemNameByID(id)
    end
    if not nombre and GetItemInfo then
        nombre = GetItemInfo(id)
    end
    if not nombre and D and D.n then
        nombre = D.n[id]
    end
    return nombre or ("objeto " .. id)
end

local function Imprimir(texto)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage(AMARILLO .. "Forever Subastas:" .. FIN .. " " .. texto)
    end
end
FS.Imprimir = Imprimir

---------------------------------------------------------------------------
-- Datos guardados por personaje (profesiones y recetas que conoce)
---------------------------------------------------------------------------

local function Personaje()
    ForeverSubastasDB = ForeverSubastasDB or {}
    local db = ForeverSubastasDB
    db.pj = db.pj or {}
    local clave = (UnitName and UnitName("player") or "?") .. "-" .. (GetRealmName and GetRealmName() or "?")
    local pj = db.pj[clave]
    if not pj then
        pj = {}
        db.pj[clave] = pj
    end
    pj.profs = pj.profs or {}
    pj.conocidas = pj.conocidas or {}
    pj.nombres = pj.nombres or {}
    return pj, db
end
FS.Personaje = Personaje

local function ActualizarProfesiones()
    if not (GetProfessions and GetProfessionInfo) then return end
    local pj = Personaje()
    local a, b, c, d, e, f = GetProfessions()
    local nuevas = {}
    for _, indice in pairs({ a, b, c, d, e, f }) do
        local ok, nombre, _, nivel, _, _, _, linea = pcall(GetProfessionInfo, indice)
        if ok and linea then
            nuevas[linea] = nivel or 0
        end
    end
    if next(nuevas) then pj.profs = nuevas end
end

local function LeerRecetasConocidas()
    local T = C_TradeSkillUI
    if not (T and T.GetAllRecipeIDs and T.GetRecipeInfo) then return end
    if T.IsTradeSkillLinked and T.IsTradeSkillLinked() then return end
    if T.IsTradeSkillGuild and T.IsTradeSkillGuild() then return end
    if T.IsNPCCrafting and T.IsNPCCrafting() then return end
    local pj = Personaje()
    local ids = T.GetAllRecipeIDs() or {}
    local n = 0
    for _, rid in ipairs(ids) do
        local info = T.GetRecipeInfo(rid)
        if info and info.learned then
            local item
            if T.GetRecipeOutputItemData then
                local ok, salida = pcall(T.GetRecipeOutputItemData, rid)
                if ok and type(salida) == "table" then item = salida.itemID end
            end
            if not item and T.GetRecipeItemLink then
                local ok, enlace = pcall(T.GetRecipeItemLink, rid)
                if ok and enlace and GetItemInfoInstant then item = GetItemInfoInstant(enlace) end
            end
            if item then pj.conocidas[item] = true end
            if info.name then pj.nombres[info.name] = true end
            n = n + 1
        end
    end
    return n
end

local function Conocida(pj, r)
    return pj.conocidas[r[R_ITEM]] or pj.nombres[r[R_NOMBRE]] or false
end

local porItem, porReactivo
local function Indices()
    if porItem then return porItem, porReactivo end
    porItem, porReactivo = {}, {}
    for _, r in ipairs(D and D.r or {}) do
        local lista = porItem[r[R_ITEM]]
        if not lista then
            lista = {}
            porItem[r[R_ITEM]] = lista
        end
        table.insert(lista, r)
        for _, m in ipairs(r[R_REAG] or {}) do
            local usos = porReactivo[m[1]]
            if not usos then
                usos = {}
                porReactivo[m[1]] = usos
            end
            table.insert(usos, r)
        end
    end
    return porItem, porReactivo
end

---------------------------------------------------------------------------
-- Tooltip de objetos
---------------------------------------------------------------------------

local function AnadirFabricacion(tt, id)
    local pi, pr = Indices()
    local pj = Personaje()
    -- 1) Si el objeto se fabrica: coste y beneficio de cada receta (máximo 2, primero las tuyas).
    local recetas = pi[id]
    if recetas then
        local orden = {}
        for _, r in ipairs(recetas) do table.insert(orden, r) end
        table.sort(orden, function(x, y)
            local cx, cy = Conocida(pj, x) and 1 or 0, Conocida(pj, y) and 1 or 0
            if cx ~= cy then return cx > cy end
            return (x[R_BENEF] or 0) > (y[R_BENEF] or 0)
        end)
        for k = 1, math.min(2, #orden) do
            local r = orden[k]
            local prof = D.p[r[R_PROF]] or "profesión"
            local quien = Conocida(pj, r) and "" or (GRIS .. " (no la conoces)" .. FIN)
            local benef = Moneda(r[R_BENEF])
            if r[R_FALTA] then benef = benef .. ROJO .. " *" .. FIN end
            tt:AddDoubleLine("Si lo fabricas (" .. prof .. ")" .. quien, benef, 1, 0.82, 0, 1, 1, 1)
            tt:AddDoubleLine(GRIS .. "   materiales " .. FIN .. Moneda(r[R_COSTE]),
                GRIS .. "venta neta " .. FIN .. Moneda(r[R_VENTA]), 1, 1, 1, 1, 1, 1)
        end
    end
    -- 2) Si es material de tus profesiones: la receta más rentable en la que usarlo.
    local usos = pr[id]
    if usos and next(pj.profs) then
        local mejor
        for _, r in ipairs(usos) do
            if pj.profs[r[R_PROF]] and not r[R_FALTA] and (r[R_BENEF] or 0) > 0 then
                if not mejor or r[R_BENEF] > mejor[R_BENEF] then mejor = r end
            end
        end
        if mejor then
            tt:AddDoubleLine("Mejor receta tuya con esto", mejor[R_NOMBRE] .. " (" .. Moneda(mejor[R_BENEF]) .. ")",
                1, 0.82, 0, 1, 1, 1)
        end
    end
end

local function AnadirTooltip(tt, id)
    if not (D and D.i and type(id) == "number") then return end
    local d = D.i[id]
    if not d then return end
    tt:AddLine(" ")
    tt:AddLine(AMARILLO .. "Subasta Alianza JcJ" .. FIN .. GRIS .. "  (datos " .. (D.ultimaDescarga or "?") .. ")" .. FIN)
    tt:AddDoubleLine("Mínimo ahora", d[I_MIN] and Moneda(d[I_MIN]) or (GRIS .. "no hay a la venta" .. FIN), 1, 1, 1, 1, 1, 1)
    if d[I_CMP] and d[I_CMP] ~= d[I_MIN] then
        tt:AddDoubleLine("Precio habitual (24 h)", Moneda(d[I_CMP]), 1, 1, 1, 1, 1, 1)
    end
    if d[I_PV] then
        tt:AddDoubleLine("Se vende de verdad a", Moneda(d[I_PV]), 1, 1, 1, 1, 1, 1)
    end
    tt:AddDoubleLine("Ventas al día", Ventas(d[I_VD]), 1, 1, 1, 1, 1, 1)
    if d[I_BH] then
        tt:AddDoubleLine("Más barato", Hora(d[I_BH]) .. (d[I_AB] and string.format(" (-%.0f%%)", d[I_AB]) or ""), 1, 1, 1, 0.3, 1, 0.3)
    end
    if d[I_SH] then
        tt:AddDoubleLine("Más caro", Hora(d[I_SH]) .. (d[I_AS] and string.format(" (+%.0f%%)", d[I_AS]) or ""), 1, 1, 1, 1, 0.6, 0.2)
    end
    if d[I_BD] and d[I_SD] then
        tt:AddDoubleLine("Por días", "compra el " .. DIAS[d[I_BD] + 1] .. ", vende el " .. DIAS[d[I_SD] + 1], 1, 1, 1, 1, 1, 1)
    end
    local t7, t24 = Tendencia(d[I_T7]), Tendencia(d[I_T24])
    if t7 or t24 then
        local partes = {}
        if t7 then table.insert(partes, "7 días: " .. t7) end
        if t24 then table.insert(partes, "24 h: " .. t24) end
        tt:AddDoubleLine("Tendencia", table.concat(partes, GRIS .. " · " .. FIN), 1, 1, 1, 1, 1, 1)
    end
    AnadirFabricacion(tt, id)
    tt:Show()
end

local function IdDeTooltip(tt, data)
    local id = data and data.id
    if issecretvalue and id ~= nil and issecretvalue(id) then return nil end
    if type(id) ~= "number" and tt.GetItem then
        local ok, _, enlace = pcall(tt.GetItem, tt)
        if ok and enlace and GetItemInfoInstant then id = GetItemInfoInstant(enlace) end
    end
    return type(id) == "number" and id or nil
end

local function EngancharTooltips()
    if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
        TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tt, data)
            pcall(function() AnadirTooltip(tt, IdDeTooltip(tt, data)) end)
        end)
    elseif GameTooltip and GameTooltip.HookScript then
        GameTooltip:HookScript("OnTooltipSetItem", function(tt)
            pcall(function() AnadirTooltip(tt, IdDeTooltip(tt, nil)) end)
        end)
    end
end

---------------------------------------------------------------------------
-- Ventana "¿Qué me conviene fabricar?"
---------------------------------------------------------------------------

local VISIBLES = 16
local ALTO_FILA = 20
local estado = { prof = "mias", orden = "unidad", soloVenta = true, soloConocidas = false, offset = 0 }
local lista = {}
local ventana

local function OpcionesProfesion()
    local opciones = { "mias", "todas" }
    local ids = {}
    for pid in pairs(D.p or {}) do table.insert(ids, pid) end
    table.sort(ids, function(x, y) return (D.p[x] or "") < (D.p[y] or "") end)
    for _, pid in ipairs(ids) do table.insert(opciones, pid) end
    return opciones
end

local function TextoProfesion(p)
    if p == "mias" then return "Mis profesiones" end
    if p == "todas" then return "Todas" end
    return D.p[p] or tostring(p)
end

local function ConstruirLista()
    local pj = Personaje()
    local prof = estado.prof
    if prof == "mias" and not next(pj.profs) then prof = "todas" end
    lista = {}
    for _, r in ipairs(D.r or {}) do
        local valida = true
        if prof == "mias" then
            valida = pj.profs[r[R_PROF]] ~= nil
        elseif prof ~= "todas" then
            valida = r[R_PROF] == prof
        end
        local conocida = Conocida(pj, r)
        -- Sin medir aún (nil) se muestra; solo se ocultan las que se sabe que casi no se venden.
        if valida and estado.soloVenta and r[R_VD] ~= nil then valida = r[R_VD] >= 1 end
        if valida and estado.soloConocidas then valida = conocida end
        if valida then table.insert(lista, { r = r, conocida = conocida }) end
    end
    local function clave(x)
        local r = x.r
        local b = r[R_BENEF] or 0
        if estado.orden == "dia" then b = b * math.min(r[R_VD] or 0, 20) end
        return b
    end
    table.sort(lista, function(x, y)
        local fx, fy = x.r[R_FALTA] and 1 or 0, y.r[R_FALTA] and 1 or 0
        if fx ~= fy then return fx < fy end
        return clave(x) > clave(y)
    end)
    if estado.offset > math.max(0, #lista - VISIBLES) then estado.offset = math.max(0, #lista - VISIBLES) end
end

local function ResumenMercado()
    local ph = D.mercado and D.mercado.precioHora
    if not ph then return "" end
    local bajo, alto
    for h = 1, 24 do
        local v = ph[h]
        if v then
            if not bajo or v < ph[bajo] then bajo = h end
            if not alto or v > ph[alto] then alto = h end
        end
    end
    if not bajo or bajo == alto then
        return GRIS .. "Las mejores horas aparecerán cuando haya 3 días de historial." .. FIN
    end
    return string.format("En general la subasta está más barata a las %s y más cara a las %s.", Hora(bajo - 1), Hora(alto - 1))
end

local function TooltipReceta(fila)
    local x = fila.dato
    if not x or not GameTooltip then return end
    local r = x.r
    GameTooltip:SetOwner(fila, "ANCHOR_RIGHT")
    if GameTooltip.SetItemByID then
        GameTooltip:SetItemByID(r[R_ITEM])
    else
        GameTooltip:SetText(r[R_NOMBRE])
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(AMARILLO .. "Receta: " .. r[R_NOMBRE] .. FIN .. (x.conocida and (VERDE .. "  (la conoces)" .. FIN) or (GRIS .. "  (no la conoces)" .. FIN)))
    GameTooltip:AddLine("Materiales:")
    for _, m in ipairs(r[R_REAG] or {}) do
        local id, cant, precio, fuente = m[1], m[2], m[3], m[4]
        local donde = fuente == "v" and (GRIS .. " vendedor" .. FIN) or ""
        GameTooltip:AddDoubleLine("  " .. cant .. "x " .. NombreObjeto(id) .. donde,
            precio and Moneda(precio * cant) or (ROJO .. "sin precio" .. FIN), 1, 1, 1, 1, 1, 1)
    end
    GameTooltip:AddDoubleLine("Coste total", Moneda(r[R_COSTE]), 1, 1, 1, 1, 1, 1)
    local di = D.i and D.i[r[R_ITEM]]
    if di and (di[I_T7] or di[I_T24]) then
        local partes = {}
        if di[I_T7] then table.insert(partes, "7 días: " .. Tendencia(di[I_T7])) end
        if di[I_T24] then table.insert(partes, "24 h: " .. Tendencia(di[I_T24])) end
        GameTooltip:AddDoubleLine("Precio del producto", table.concat(partes, " · "), 1, 1, 1, 1, 1, 1)
    end
    local textoVenta = "Venta neta (tras 5% de la subasta)"
    if r[R_DONDE] == "vendedor" then textoVenta = "Venta al vendedor (mejor que la subasta)" end
    if r[R_DONDE] == "mercado" then textoVenta = textoVenta .. GRIS .. " · precio de mercado" .. FIN end
    if r[R_DONDE] == "real" then textoVenta = textoVenta .. VERDE .. " · ventas reales" .. FIN end
    GameTooltip:AddDoubleLine(textoVenta, Moneda(r[R_VENTA]), 1, 1, 1, 1, 1, 1)
    GameTooltip:AddDoubleLine("Beneficio por fabricación", Moneda(r[R_BENEF]), 1, 1, 1, 1, 1, 1)
    if r[R_FALTA] then
        GameTooltip:AddLine(ROJO .. "Ojo: hay materiales sin precio en la subasta; el coste real será mayor." .. FIN, 1, 1, 1, true)
    end
    GameTooltip:Show()
end

local function Refrescar()
    if not ventana or not ventana:IsShown() then return end
    ConstruirLista()
    ventana.botonProf:SetText("Profesión: " .. TextoProfesion(estado.prof))
    ventana.botonOrden:SetText(estado.orden == "dia" and "Orden: beneficio x ventas" or "Orden: por unidad")
    ventana.botonVenta:SetText("Solo lo que se vende: " .. (estado.soloVenta and "sí" or "no"))
    ventana.botonConocidas:SetText("Solo las que conozco: " .. (estado.soloConocidas and "sí" or "no"))

    for i = 1, VISIBLES do
        local fila = ventana.filas[i]
        local x = lista[estado.offset + i]
        fila.dato = x
        if x then
            local r = x.r
            local color = x.conocida and "|cffffffff" or GRIS
            local nombre = r[R_NOMBRE]
            if r[R_FALTA] then nombre = nombre .. ROJO .. " *" .. FIN end
            fila.nombre:SetText(color .. nombre .. FIN)
            fila.prof:SetText(GRIS .. (D.p[r[R_PROF]] or "") .. FIN)
            fila.benef:SetText(Moneda(r[R_BENEF]))
            fila.ventas:SetText(Ventas(r[R_VD]))
            local di = D.i and D.i[r[R_ITEM]]
            local t7 = di and di[I_T7]
            if t7 == nil then
                fila.tend:SetText(GRIS .. "-" .. FIN)
            elseif math.abs(t7) < 3 then
                fila.tend:SetText("=")
            else
                fila.tend:SetText((t7 > 0 and VERDE or ROJO) .. string.format("%+.0f%%", t7) .. FIN)
            end
            fila.coste:SetText(Moneda(r[R_COSTE]))
            fila.venta:SetText(Moneda(r[R_VENTA]))
            fila:Show()
        else
            fila:Hide()
        end
    end

    local edad = HorasDesde(D.generadoTs)
    local aviso = ""
    if edad and edad > 6 then
        aviso = ROJO .. string.format("  ¡Datos de hace %.0f h! Revisa la actualización del PC.", edad) .. FIN
    end
    ventana.info:SetText(string.format("Datos de la subasta: %s · historial: %.1f días%s",
        D.ultimaDescarga or "?", D.dias or 0, aviso))
    local desde = #lista > 0 and (estado.offset + 1) or 0
    ventana.pie:SetText(string.format("%d-%d de %d recetas · rueda del ratón para desplazarte · %s",
        desde, math.min(estado.offset + VISIBLES, #lista), #lista, ResumenMercado()))
end
FS.Refrescar = Refrescar

local function CrearBoton(padre, ancho, alClic)
    local b = CreateFrame("Button", nil, padre, "UIPanelButtonTemplate")
    b:SetSize(ancho, 22)
    b:SetScript("OnClick", alClic)
    return b
end

local function Texto(padre, plantilla, ancho, justificar)
    local t = padre:CreateFontString(nil, "OVERLAY", plantilla or "GameFontHighlightSmall")
    if ancho then t:SetWidth(ancho) end
    t:SetJustifyH(justificar or "LEFT")
    t:SetWordWrap(false)
    return t
end

local COLUMNAS = {
    { "nombre", "Receta", 200, "LEFT" },
    { "prof", "Profesión", 90, "LEFT" },
    { "benef", "Beneficio", 90, "RIGHT" },
    { "ventas", "Ventas/día", 62, "RIGHT" },
    { "tend", "Precio 7 d", 70, "RIGHT" },
    { "coste", "Coste", 80, "RIGHT" },
    { "venta", "Venta", 80, "RIGHT" },
}

local function CrearVentana()
    local ok, f = pcall(CreateFrame, "Frame", "ForeverSubastasVentana", UIParent, "BasicFrameTemplateWithInset")
    if not ok or not f then
        f = CreateFrame("Frame", "ForeverSubastasVentana", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
        if f.SetBackdrop then
            f:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
                edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border", tile = true, tileSize = 32, edgeSize = 32,
                insets = { left = 8, right = 8, top = 8, bottom = 8 } })
        end
        local cerrar = CreateFrame("Button", nil, f, "UIPanelCloseButton")
        cerrar:SetPoint("TOPRIGHT", -4, -4)
    end
    f:SetSize(740, 500)
    f:SetPoint("CENTER")
    f:SetFrameStrata("HIGH")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetClampedToScreen(true)
    if UISpecialFrames then table.insert(UISpecialFrames, "ForeverSubastasVentana") end

    local titulo = Texto(f, "GameFontNormal", 600, "CENTER")
    titulo:SetPoint("TOP", 0, -6)
    titulo:SetText("Forever Subastas · ¿Qué me conviene fabricar?")

    f.info = Texto(f, "GameFontHighlightSmall", 690)
    f.info:SetPoint("TOPLEFT", 16, -32)

    f.botonProf = CrearBoton(f, 200, function(_, boton)
        local opciones = OpcionesProfesion()
        local actual = 1
        for i, o in ipairs(opciones) do if o == estado.prof then actual = i end end
        local paso = boton == "RightButton" and -1 or 1
        estado.prof = opciones[(actual - 1 + paso) % #opciones + 1]
        estado.offset = 0
        Refrescar()
    end)
    f.botonProf:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    f.botonProf:SetPoint("TOPLEFT", 14, -50)

    f.botonOrden = CrearBoton(f, 170, function()
        estado.orden = estado.orden == "unidad" and "dia" or "unidad"
        estado.offset = 0
        Refrescar()
    end)
    f.botonOrden:SetPoint("LEFT", f.botonProf, "RIGHT", 6, 0)

    f.botonVenta = CrearBoton(f, 160, function()
        estado.soloVenta = not estado.soloVenta
        estado.offset = 0
        Refrescar()
    end)
    f.botonVenta:SetPoint("LEFT", f.botonOrden, "RIGHT", 6, 0)

    f.botonConocidas = CrearBoton(f, 160, function()
        estado.soloConocidas = not estado.soloConocidas
        estado.offset = 0
        Refrescar()
    end)
    f.botonConocidas:SetPoint("LEFT", f.botonVenta, "RIGHT", 6, 0)

    -- Cabecera de columnas
    local x = 18
    for _, c in ipairs(COLUMNAS) do
        local t = Texto(f, "GameFontNormalSmall", c[3], c[4])
        t:SetPoint("TOPLEFT", x, -82)
        t:SetText(c[2])
        x = x + c[3] + 6
    end

    f.filas = {}
    for i = 1, VISIBLES do
        local fila = CreateFrame("Button", nil, f)
        fila:SetSize(710, ALTO_FILA)
        fila:SetPoint("TOPLEFT", 14, -98 - (i - 1) * ALTO_FILA)
        local resalte = fila:CreateTexture(nil, "HIGHLIGHT")
        resalte:SetAllPoints()
        resalte:SetColorTexture(1, 1, 1, 0.08)
        if i % 2 == 0 then
            local fondo = fila:CreateTexture(nil, "BACKGROUND")
            fondo:SetAllPoints()
            fondo:SetColorTexture(1, 1, 1, 0.03)
        end
        local cx = 4
        for _, c in ipairs(COLUMNAS) do
            local t = Texto(fila, "GameFontHighlightSmall", c[3], c[4])
            t:SetPoint("LEFT", cx, 0)
            fila[c[1]] = t
            cx = cx + c[3] + 6
        end
        fila:SetScript("OnEnter", TooltipReceta)
        fila:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
        f.filas[i] = fila
    end

    f.pie = Texto(f, "GameFontHighlightSmall", 690)
    f.pie:SetPoint("BOTTOMLEFT", 16, 12)

    f:EnableMouseWheel(true)
    f:SetScript("OnMouseWheel", function(_, delta)
        local maximo = math.max(0, #lista - VISIBLES)
        estado.offset = math.min(maximo, math.max(0, estado.offset - delta * 3))
        Refrescar()
    end)
    f:SetScript("OnShow", Refrescar)
    f:Hide()
    return f
end

function FS.Mostrar(profesion)
    if not D then
        Imprimir("no encuentro los datos (falta Datos.lua).")
        return
    end
    ventana = ventana or CrearVentana()
    if profesion then
        estado.prof = profesion
        estado.offset = 0
    end
    if ventana:IsShown() and not profesion then
        ventana:Hide()
    else
        ventana:Show()
        Refrescar()
    end
end

---------------------------------------------------------------------------
-- Botones en la ventana de profesiones y en la subasta
---------------------------------------------------------------------------

local function ProfesionAbierta()
    local T = C_TradeSkillUI
    if T and T.GetBaseProfessionInfo then
        local ok, info = pcall(T.GetBaseProfessionInfo)
        if ok and info and info.professionID and D.p[info.professionID] then return info.professionID end
    end
    if T and T.GetTradeSkillLine then
        local ok, linea = pcall(T.GetTradeSkillLine)
        if ok and linea and D.p[linea] then return linea end
    end
    return nil
end

local function BotonEn(marco, texto, alClic)
    if not marco or marco.ForeverSubastasBoton then return end
    local ok, b = pcall(CreateFrame, "Button", nil, marco, "UIPanelButtonTemplate")
    if not ok or not b then return end
    b:SetSize(120, 22)
    b:SetText(texto)
    b:SetPoint("TOPRIGHT", marco, "TOPRIGHT", -30, -26)
    b:SetFrameStrata("HIGH")
    b:SetScript("OnClick", alClic)
    marco.ForeverSubastasBoton = b
end

local function CrearBotonesExternos()
    if ProfessionsFrame then
        BotonEn(ProfessionsFrame, "Rentabilidad", function() FS.Mostrar(ProfesionAbierta() or "mias") end)
    elseif TradeSkillFrame then
        BotonEn(TradeSkillFrame, "Rentabilidad", function() FS.Mostrar(ProfesionAbierta() or "mias") end)
    end
    if AuctionHouseFrame then
        BotonEn(AuctionHouseFrame, "Forever Subastas", function() FS.Mostrar() end)
    end
end

---------------------------------------------------------------------------
-- Eventos y comandos
---------------------------------------------------------------------------

local eventos = CreateFrame("Frame")
eventos:RegisterEvent("PLAYER_LOGIN")
eventos:RegisterEvent("SKILL_LINES_CHANGED")
eventos:RegisterEvent("TRADE_SKILL_SHOW")
eventos:RegisterEvent("TRADE_SKILL_LIST_UPDATE")
eventos:RegisterEvent("ADDON_LOADED")
eventos:SetScript("OnEvent", function(_, evento, arg1)
    if evento == "PLAYER_LOGIN" then
        D = ForeverSubastasDatos
        pcall(ActualizarProfesiones)
        pcall(EngancharTooltips)
        pcall(CrearBotonesExternos)
        if D then
            local edad = HorasDesde(D.generadoTs)
            local texto = "datos de la subasta del " .. (D.ultimaDescarga or "?") .. ". Escribe /subastas para ver qué te conviene fabricar."
            if edad and edad > 6 then
                texto = texto .. ROJO .. string.format(" Ojo: los datos tienen %.0f h.", edad) .. FIN
            end
            Imprimir(texto)
        else
            Imprimir("no encuentro Datos.lua.")
        end
    elseif evento == "SKILL_LINES_CHANGED" then
        pcall(ActualizarProfesiones)
    elseif evento == "TRADE_SKILL_SHOW" or evento == "TRADE_SKILL_LIST_UPDATE" then
        pcall(LeerRecetasConocidas)
        pcall(CrearBotonesExternos)
    elseif evento == "ADDON_LOADED" and (arg1 == "Blizzard_Professions" or arg1 == "Blizzard_AuctionHouseUI"
            or arg1 == "Blizzard_TradeSkillUI") then
        pcall(CrearBotonesExternos)
    end
end)

SLASH_FOREVERSUBASTAS1 = "/subastas"
SLASH_FOREVERSUBASTAS2 = "/fsub"
SlashCmdList = SlashCmdList or {}
SlashCmdList["FOREVERSUBASTAS"] = function(texto)
    texto = (texto or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    if texto == "ayuda" or texto == "help" then
        Imprimir("/subastas abre o cierra la ventana de rentabilidad. Pasa el ratón por cualquier objeto para ver precios, ventas y mejores horas. Abre tus profesiones una vez para que sepa qué recetas conoces.")
    elseif texto == "todas" then
        FS.Mostrar("todas")
    else
        FS.Mostrar()
    end
end
