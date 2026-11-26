-- Forever Subastas
-- Muestra en el juego lo que calcula el analizador en la nube (forever-subastas):
-- precios, ventas reales, tendencias, mejores horas, precio recomendado de venta,
-- rentabilidad de recetas, listas de la compra para Auctionator y registro de tus cuentas.

local FS = {}
_G.ForeverSubastas = FS

local D = ForeverSubastasDatos
local GetItemInfo = GetItemInfo or (C_Item and C_Item.GetItemInfo)
local GetItemInfoInstant = GetItemInfoInstant or (C_Item and C_Item.GetItemInfoInstant)

local DIAS = { "lunes", "martes", "miércoles", "jueves", "viernes", "sábado", "domingo" }
local AMARILLO, GRIS, VERDE, ROJO, NARANJA, BLANCO, FIN =
    "|cffffd100", "|cff9d9d9d", "|cff1eff00", "|cffff4040", "|cffff9933", "|cffffffff", "|r"

-- Posiciones dentro de D.i[id]
local I_MIN, I_CMP, I_PV, I_VD, I_CANT, I_BH, I_SH, I_AB, I_AS, I_BD, I_SD = 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11
local I_T24, I_T7, I_HV, I_REC, I_RECP, I_CURVA = 15, 16, 17, 18, 19, 20
-- Posiciones dentro de cada receta de D.r
local R_PROF, R_NOMBRE, R_ITEM, R_COSTE, R_VENTA, R_BENEF, R_VD, R_DONDE, R_REAG, R_FALTA = 2, 3, 4, 6, 7, 8, 9, 10, 11, 12

local MAX_OPERACIONES = 5000

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

local function HoraActual()
    local t = date and date("*t")
    return t and t.hour or 12
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

local function TendenciaCorta(t)
    if t == nil then return GRIS .. "-" .. FIN end
    if math.abs(t) < 3 then return "=" end
    return (t > 0 and VERDE or ROJO) .. string.format("%+.0f%%", t) .. FIN
end

local function HorasDesde(ts)
    if not ts or not time then return nil end
    return (time() - ts) / 3600
end

local function NombreObjeto(id)
    if not id then return "?" end
    local nombre
    if C_Item and C_Item.GetItemNameByID then nombre = C_Item.GetItemNameByID(id) end
    if not nombre and GetItemInfo then nombre = GetItemInfo(id) end
    if not nombre and D and D.n then nombre = D.n[id] end
    return nombre or ("objeto " .. id)
end

local nombreAId
local function IdPorNombre(nombre)
    if not nombre then return nil end
    if not nombreAId then
        nombreAId = {}
        for id, n in pairs(D and D.n or {}) do nombreAId[n] = id end
    end
    local id = nombreAId[nombre]
    if not id and GetItemInfoInstant then
        local ok, x = pcall(GetItemInfoInstant, nombre)
        if ok and type(x) == "number" then id = x end
    end
    return id
end

local function PrecioVendedor(id)
    if not GetItemInfo then return nil end
    local ok, _, _, _, _, _, _, _, _, _, _, venta = pcall(GetItemInfo, id)
    if ok and type(venta) == "number" and venta > 0 then return venta end
    return nil
end

local function ContarObjeto(id)
    if C_Item and C_Item.GetItemCount then
        local ok, n = pcall(C_Item.GetItemCount, id, true)
        if ok and n then return n end
    end
    if GetItemCount then return GetItemCount(id, true) or 0 end
    return 0
end

local function Imprimir(texto)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage(AMARILLO .. "Forever Subastas:" .. FIN .. " " .. texto)
    end
end
FS.Imprimir = Imprimir

local function Hoy()
    return date and date("%Y-%m-%d") or "?"
end

---------------------------------------------------------------------------
-- Datos guardados (por personaje: profesiones y recetas; por cuenta: operaciones)
---------------------------------------------------------------------------

local function ClavePersonaje()
    return (UnitName and UnitName("player") or "?") .. "-" .. (GetRealmName and GetRealmName() or "?")
end

local function Personaje()
    ForeverSubastasDB = ForeverSubastasDB or {}
    local db = ForeverSubastasDB
    db.pj = db.pj or {}
    local clave = ClavePersonaje()
    local pj = db.pj[clave]
    if not pj then
        pj = {}
        db.pj[clave] = pj
    end
    pj.profs = pj.profs or {}
    pj.conocidas = pj.conocidas or {}
    pj.nombres = pj.nombres or {}
    pj.oro = pj.oro or {}
    return pj, db
end
FS.Personaje = Personaje

local function Cuentas()
    local _, db = Personaje()
    db.cuentas = db.cuentas or {}
    local cu = db.cuentas
    cu.ops = cu.ops or {}
    cu.vistos = cu.vistos or {}
    return cu
end
FS.Cuentas = Cuentas

local function Anotar(tipo, item, nombre, cant, total)
    local cu = Cuentas()
    table.insert(cu.ops, { t = time and time() or 0, tipo = tipo, item = item, n = nombre or (item and NombreObjeto(item)),
        c = cant or 1, m = total or 0, pj = ClavePersonaje() })
    while #cu.ops > MAX_OPERACIONES do table.remove(cu.ops, 1) end
    if FS.RefrescarSiCuentas then FS.RefrescarSiCuentas() end
end
FS.Anotar = Anotar

local function GuardarOro()
    if not GetMoney then return end
    local pj = Personaje()
    pj.oro[Hoy()] = GetMoney()
end

local function ActualizarProfesiones()
    if not (GetProfessions and GetProfessionInfo) then return end
    local pj = Personaje()
    local a, b, c, d, e, f = GetProfessions()
    local nuevas = {}
    for _, indice in pairs({ a, b, c, d, e, f }) do
        local ok, _, _, nivel, _, _, _, linea = pcall(GetProfessionInfo, indice)
        if ok and linea then nuevas[linea] = nivel or 0 end
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
    for _, rid in ipairs(T.GetAllRecipeIDs() or {}) do
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
        end
    end
end

local function Conocida(pj, r)
    return pj.conocidas[r[R_ITEM]] or pj.nombres[r[R_NOMBRE]] or false
end

local porItem, porReactivo
local function Indices()
    if porItem then return porItem, porReactivo end
    porItem, porReactivo = {}, {}
    for _, r in ipairs(D and D.r or {}) do
        porItem[r[R_ITEM]] = porItem[r[R_ITEM]] or {}
        table.insert(porItem[r[R_ITEM]], r)
        for _, m in ipairs(r[R_REAG] or {}) do
            porReactivo[m[1]] = porReactivo[m[1]] or {}
            table.insert(porReactivo[m[1]], r)
        end
    end
    return porItem, porReactivo
end

---------------------------------------------------------------------------
-- Consejo de venta (tooltip y pestaña "Qué vender")
---------------------------------------------------------------------------

-- Devuelve {precio, prob, accion, texto}; accion: "ya", "hora", "espera", "vendedor", "nosevende".
local function ConsejoVenta(id)
    local d = D and D.i and D.i[id]
    local vendedor = PrecioVendedor(id)
    if not d then
        if vendedor then return { precio = vendedor, accion = "vendedor", texto = "Véndelo al vendedor" } end
        return nil
    end
    local precio = d[I_REC] or d[I_MIN] or d[I_CMP]
    if not precio then
        if vendedor then return { precio = vendedor, accion = "vendedor", texto = "Véndelo al vendedor" } end
        return nil
    end
    local c = { precio = precio, prob = d[I_REC] and d[I_RECP] or nil }
    if vendedor and vendedor >= precio * 0.95 then
        c.precio, c.prob, c.accion, c.texto = vendedor, nil, "vendedor", "Véndelo al vendedor (paga más)"
        return c
    end
    if d[I_VD] ~= nil and d[I_VD] < 0.3 then
        c.accion, c.texto = "nosevende", "Casi no se vende"
        return c
    end
    if d[I_PV] and d[I_MIN] and d[I_MIN] < d[I_PV] * 0.85 then
        c.precio = d[I_PV]
        c.accion = "espera"
        c.texto = string.format("Espera: hoy está un %.0f%% por debajo de lo que se paga", (1 - d[I_MIN] / d[I_PV]) * 100)
        return c
    end
    local hora = HoraActual()
    if d[I_SH] and d[I_AS] and d[I_AS] >= 5 then
        local antes = (d[I_SH] - hora) % 24
        if antes > 3 then
            c.accion = "hora"
            c.texto = string.format("Mejor ponlo antes de las %02d h (+%.0f%%)", d[I_SH], d[I_AS])
            return c
        end
    end
    c.accion, c.texto = "ya", "Buen momento para venderlo"
    return c
end
FS.ConsejoVenta = ConsejoVenta

---------------------------------------------------------------------------
-- Tooltip de objetos
---------------------------------------------------------------------------

local function AnadirFabricacion(tt, id)
    local pi, pr = Indices()
    local pj = Personaje()
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
    local t7, t24 = Tendencia(d[I_T7]), Tendencia(d[I_T24])
    if t7 or t24 then
        local partes = {}
        if t7 then table.insert(partes, "7 días: " .. t7) end
        if t24 then table.insert(partes, "24 h: " .. t24) end
        tt:AddDoubleLine("Tendencia", table.concat(partes, GRIS .. " · " .. FIN), 1, 1, 1, 1, 1, 1)
    end
    if d[I_BH] then
        tt:AddDoubleLine("Más barato", Hora(d[I_BH]) .. (d[I_AB] and string.format(" (-%.0f%%)", d[I_AB]) or ""), 1, 1, 1, 0.3, 1, 0.3)
    end
    if d[I_SH] then
        tt:AddDoubleLine("Más caro", Hora(d[I_SH]) .. (d[I_AS] and string.format(" (+%.0f%%)", d[I_AS]) or ""), 1, 1, 1, 1, 0.6, 0.2)
    end
    if d[I_HV] then
        tt:AddDoubleLine("Hora con más ventas", Hora(d[I_HV]), 1, 1, 1, 1, 1, 1)
    end
    if d[I_BD] and d[I_SD] then
        tt:AddDoubleLine("Por días", "compra el " .. DIAS[d[I_BD] + 1] .. ", vende el " .. DIAS[d[I_SD] + 1], 1, 1, 1, 1, 1, 1)
    end
    local c = ConsejoVenta(id)
    if c then
        local derecha = Moneda(c.precio)
        if c.prob then derecha = derecha .. GRIS .. string.format(" (se vende el %d%%)", c.prob) .. FIN end
        tt:AddDoubleLine("Para vender", derecha, 1, 0.82, 0, 1, 1, 1)
        tt:AddLine(GRIS .. "   " .. c.texto .. FIN)
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
-- Lista de la compra para Auctionator
---------------------------------------------------------------------------

local function CrearListaCompra(r, veces)
    local terminos, vendedor = {}, {}
    for _, m in ipairs(r[R_REAG] or {}) do
        local id, q, precio, fuente = m[1], m[2], m[3], m[4]
        local falta = q * veces - ContarObjeto(id)
        if falta > 0 then
            local nombre = NombreObjeto(id)
            if fuente == "v" then
                table.insert(vendedor, falta .. "x " .. nombre)
            else
                table.insert(terminos, { nombre = nombre, cant = falta, max = precio and math.ceil(precio * 1.2) or nil })
            end
        end
    end
    if #terminos == 0 and #vendedor == 0 then
        Imprimir("ya tienes todos los materiales para fabricar " .. veces .. "x " .. r[R_NOMBRE] .. ".")
        return
    end
    if #terminos > 0 then
        local api = Auctionator and Auctionator.API and Auctionator.API.v1
        local creada = false
        if api and api.ConvertToSearchString and api.CreateShoppingList then
            local cadenas = {}
            for _, t in ipairs(terminos) do
                local ok, cadena = pcall(api.ConvertToSearchString, "ForeverSubastas",
                    { searchString = t.nombre, isExact = true, quantity = t.cant, maxPrice = t.max })
                if ok and cadena then table.insert(cadenas, cadena) end
            end
            local nombreLista = "FS " .. r[R_NOMBRE]
            if api.DeleteShoppingList then pcall(api.DeleteShoppingList, "ForeverSubastas", nombreLista) end
            creada = pcall(api.CreateShoppingList, "ForeverSubastas", nombreLista, cadenas)
            if creada then
                Imprimir("lista de la compra \"" .. nombreLista .. "\" creada en Auctionator (pestaña de compras). " ..
                    "Precio máximo: un 20% sobre el habitual.")
            end
        end
        if not creada then
            local partes = {}
            for _, t in ipairs(terminos) do
                table.insert(partes, t.cant .. "x " .. t.nombre .. (t.max and (" (máx. " .. Moneda(t.max) .. ")") or ""))
            end
            Imprimir("compra en la subasta: " .. table.concat(partes, ", "))
        end
    end
    if #vendedor > 0 then
        Imprimir("compra al vendedor: " .. table.concat(vendedor, ", "))
    end
end
FS.CrearListaCompra = CrearListaCompra

local function CajaDeTexto(popup)
    return popup and (popup.editBox or popup.EditBox or (popup.GetEditBox and popup:GetEditBox()))
end

local function PedirVecesYCrearLista(r)
    if not (StaticPopupDialogs and StaticPopup_Show) then
        CrearListaCompra(r, 5)
        return
    end
    if not StaticPopupDialogs["FOREVERSUBASTAS_LISTA"] then
        StaticPopupDialogs["FOREVERSUBASTAS_LISTA"] = {
            text = "¿Cuántas veces quieres fabricar %s?\nSe descuenta lo que ya tienes.",
            button1 = "Crear lista",
            button2 = "Cancelar",
            hasEditBox = true,
            maxLetters = 4,
            OnShow = function(self)
                local caja = CajaDeTexto(self)
                if caja then
                    caja:SetText("5")
                    caja:HighlightText()
                end
            end,
            OnAccept = function(self, receta)
                local caja = CajaDeTexto(self)
                local n = tonumber(caja and caja:GetText() or "") or 5
                CrearListaCompra(receta or self.data, math.max(1, math.floor(n)))
            end,
            EditBoxOnEnterPressed = function(self)
                local popup = self:GetParent()
                local n = tonumber(self:GetText() or "") or 5
                CrearListaCompra(popup.data, math.max(1, math.floor(n)))
                popup:Hide()
            end,
            timeout = 0,
            whileDead = true,
            hideOnEscape = true,
            preferredIndex = 3,
        }
    end
    StaticPopup_Show("FOREVERSUBASTAS_LISTA", r[R_NOMBRE], nil, r)
end

---------------------------------------------------------------------------
-- Registro de operaciones (Mis cuentas)
---------------------------------------------------------------------------

local function LeerFacturas()
    if not (GetInboxNumItems and GetInboxInvoiceInfo and GetInboxHeaderInfo) then return end
    local cu = Cuentas()
    local ahora = time()
    for i = 1, GetInboxNumItems() do
        local _, _, _, _, _, _, diasRestantes = GetInboxHeaderInfo(i)
        local tipo, nombre, jugador, puja, _, deposito, comision, _, _, cantidad = GetInboxInvoiceInfo(i)
        if (tipo == "seller" or tipo == "buyer") and diasRestantes then
            local enviado = math.floor((ahora + (diasRestantes - 30) * 86400) / 3600)
            local base = table.concat({ tipo, nombre or "", jugador or "", puja or 0, cantidad or 0 }, "|")
            local visto = cu.vistos[base .. "|" .. enviado] or cu.vistos[base .. "|" .. (enviado - 1)]
                or cu.vistos[base .. "|" .. (enviado + 1)]
            if not visto then
                cu.vistos[base .. "|" .. enviado] = ahora
                local item = IdPorNombre(nombre)
                if tipo == "seller" then
                    Anotar("venta", item, nombre, cantidad or 1, (puja or 0) - (comision or 0))
                else
                    Anotar("compra", item, nombre, cantidad or 1, puja or 0)
                end
            end
        end
    end
    -- Olvidar facturas de hace más de 35 días.
    for clave, cuando in pairs(cu.vistos) do
        if type(cuando) ~= "number" or ahora - cuando > 35 * 86400 then cu.vistos[clave] = nil end
    end
end

local ultimoTotalCompra, compraPendiente, eventoCompraOk

local function EngancharSubasta()
    local AH = C_AuctionHouse
    if not (AH and hooksecurefunc) or FS.subastaEnganchada then return end
    FS.subastaEnganchada = true
    if AH.ConfirmCommoditiesPurchase then
        hooksecurefunc(AH, "ConfirmCommoditiesPurchase", function(itemID, cantidad)
            compraPendiente = { item = itemID, cant = cantidad, total = ultimoTotalCompra }
            if not eventoCompraOk then
                Anotar("compra", itemID, nil, cantidad, ultimoTotalCompra or 0)
                compraPendiente = nil
            end
        end)
    end
    local function IdDe(ubicacion)
        if C_Item and C_Item.GetItemID then
            local ok, id = pcall(C_Item.GetItemID, ubicacion)
            if ok then return id end
        end
        return nil
    end
    if AH.PostCommodity then
        hooksecurefunc(AH, "PostCommodity", function(ubicacion, _, cantidad, precioUnidad)
            local id = IdDe(ubicacion)
            if id then Anotar("publica", id, nil, cantidad or 1, (precioUnidad or 0) * (cantidad or 1)) end
        end)
    end
    if AH.PostItem then
        hooksecurefunc(AH, "PostItem", function(ubicacion, _, cantidad, _, compra)
            local id = IdDe(ubicacion)
            if id then Anotar("publica", id, nil, cantidad or 1, compra or 0) end
        end)
    end
end

-- Resumen por producto en los últimos `dias` días (nil = todo).
local function ResumenCuentas(dias)
    local cu = Cuentas()
    local desde = dias and (time() - dias * 86400) or 0
    local porProducto, tot = {}, { ventas = 0, compras = 0, nv = 0, nc = 0 }
    for _, op in ipairs(cu.ops) do
        if op.t >= desde and op.tipo ~= "fabrica" then
            local clave = op.item or op.n or "?"
            local p = porProducto[clave]
            if not p then
                p = { item = op.item, n = op.n, vend = 0, ingresos = 0, comp = 0, gastos = 0, publ = 0, ultima = nil }
                porProducto[clave] = p
            end
            if op.tipo == "venta" then
                p.vend, p.ingresos = p.vend + op.c, p.ingresos + op.m
                p.ultima = math.max(p.ultima or 0, op.t)
                tot.ventas, tot.nv = tot.ventas + op.m, tot.nv + 1
            elseif op.tipo == "compra" then
                p.comp, p.gastos = p.comp + op.c, p.gastos + op.m
                tot.compras, tot.nc = tot.compras + op.m, tot.nc + 1
            elseif op.tipo == "publica" then
                p.publ = p.publ + op.c
            end
        end
    end
    local lista = {}
    for _, p in pairs(porProducto) do
        p.balance = p.ingresos - p.gastos
        table.insert(lista, p)
    end
    table.sort(lista, function(x, y) return x.balance > y.balance end)
    return lista, tot
end
FS.ResumenCuentas = ResumenCuentas

local function OroHaceDias(n)
    local pj = Personaje()
    if not date or not time then return nil end
    local objetivo = date("%Y-%m-%d", time() - n * 86400)
    local mejor
    for dia, oro in pairs(pj.oro) do
        if dia <= objetivo and (not mejor or dia > mejor[1]) then mejor = { dia, oro } end
    end
    return mejor and mejor[2] or nil
end

---------------------------------------------------------------------------
-- Ventana: pestañas "Qué fabricar", "Qué vender" y "Mis cuentas"
---------------------------------------------------------------------------

local VISIBLES = 16
local ALTO_FILA = 20
local NUM_COLUMNAS = 7
local estado = { modo = "fabricar", prof = "mias", orden = "unidad", soloVenta = true, soloConocidas = false,
    offset = 0, periodo = 7 }
local lista = {}
local ventana

local COLUMNAS = {
    fabricar = {
        { "Receta", 200, "LEFT" }, { "Profesión", 90, "LEFT" }, { "Beneficio", 90, "RIGHT" },
        { "Ventas/día", 62, "RIGHT" }, { "Precio 7 d", 70, "RIGHT" }, { "Coste", 80, "RIGHT" }, { "Venta", 80, "RIGHT" },
    },
    vender = {
        { "Objeto", 190, "LEFT" }, { "Tienes", 45, "RIGHT" }, { "Ponlo a", 85, "RIGHT" }, { "Se vende", 55, "RIGHT" },
        { "Total", 85, "RIGHT" }, { "Ventas/día", 62, "RIGHT" }, { "Consejo", 160, "LEFT" },
    },
    cuentas = {
        { "Producto", 190, "LEFT" }, { "Vendido", 70, "RIGHT" }, { "Ingresos", 90, "RIGHT" }, { "Comprado", 65, "RIGHT" },
        { "Gastos", 90, "RIGHT" }, { "Balance", 90, "RIGHT" }, { "Última venta", 75, "RIGHT" },
    },
}

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

local function ListaFabricar()
    local pj = Personaje()
    local prof = estado.prof
    if prof == "mias" and not next(pj.profs) then prof = "todas" end
    local salida = {}
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
        if valida then table.insert(salida, { r = r, conocida = conocida }) end
    end
    local function clave(x)
        local b = x.r[R_BENEF] or 0
        if estado.orden == "dia" then b = b * math.min(x.r[R_VD] or 0, 20) end
        return b
    end
    table.sort(salida, function(x, y)
        local fx, fy = x.r[R_FALTA] and 1 or 0, y.r[R_FALTA] and 1 or 0
        if fx ~= fy then return fx < fy end
        return clave(x) > clave(y)
    end)
    return salida
end

local function LeerBolsas()
    local cuenta = {}
    local C = C_Container
    for bolsa = 0, 5 do
        local n = 0
        if C and C.GetContainerNumSlots then
            n = C.GetContainerNumSlots(bolsa) or 0
        elseif GetContainerNumSlots then
            n = GetContainerNumSlots(bolsa) or 0
        end
        for hueco = 1, n do
            local info = C and C.GetContainerItemInfo and C.GetContainerItemInfo(bolsa, hueco)
            if info and info.itemID and not info.isBound then
                cuenta[info.itemID] = (cuenta[info.itemID] or 0) + (info.stackCount or 1)
            end
        end
    end
    return cuenta
end

local function ListaVender()
    local salida = {}
    local total = 0
    for id, cant in pairs(LeerBolsas()) do
        local c = ConsejoVenta(id)
        if c and c.precio then
            local neto = c.accion == "vendedor" and c.precio * cant or c.precio * cant * 0.95
            total = total + neto
            table.insert(salida, { id = id, cant = cant, c = c, total = neto })
        end
    end
    table.sort(salida, function(x, y) return x.total > y.total end)
    return salida, total
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
        return GRIS .. "Las mejores horas aparecerán con 3 días de historial." .. FIN
    end
    return string.format("La subasta suele estar más barata a las %s y más cara a las %s.", Hora(bajo - 1), Hora(alto - 1))
end

local function TooltipReceta(fila, r, conocida)
    GameTooltip:SetOwner(fila, "ANCHOR_RIGHT")
    if GameTooltip.SetItemByID then GameTooltip:SetItemByID(r[R_ITEM]) else GameTooltip:SetText(r[R_NOMBRE]) end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(AMARILLO .. "Receta: " .. r[R_NOMBRE] .. FIN ..
        (conocida and (VERDE .. "  (la conoces)" .. FIN) or (GRIS .. "  (no la conoces)" .. FIN)))
    GameTooltip:AddLine("Materiales:")
    for _, m in ipairs(r[R_REAG] or {}) do
        local id, cant, precio, fuente = m[1], m[2], m[3], m[4]
        local donde = fuente == "v" and (GRIS .. " vendedor" .. FIN) or ""
        GameTooltip:AddDoubleLine("  " .. cant .. "x " .. NombreObjeto(id) .. donde,
            precio and Moneda(precio * cant) or (ROJO .. "sin precio" .. FIN), 1, 1, 1, 1, 1, 1)
    end
    GameTooltip:AddDoubleLine("Coste total", Moneda(r[R_COSTE]), 1, 1, 1, 1, 1, 1)
    local textoVenta = "Venta neta (tras 5% de la subasta)"
    if r[R_DONDE] == "vendedor" then textoVenta = "Venta al vendedor (mejor que la subasta)" end
    if r[R_DONDE] == "mercado" then textoVenta = textoVenta .. GRIS .. " · precio de mercado" .. FIN end
    if r[R_DONDE] == "real" then textoVenta = textoVenta .. VERDE .. " · ventas reales" .. FIN end
    GameTooltip:AddDoubleLine(textoVenta, Moneda(r[R_VENTA]), 1, 1, 1, 1, 1, 1)
    GameTooltip:AddDoubleLine("Beneficio por fabricación", Moneda(r[R_BENEF]), 1, 1, 1, 1, 1, 1)
    if r[R_FALTA] then
        GameTooltip:AddLine(ROJO .. "Ojo: hay materiales sin precio en la subasta; el coste real será mayor." .. FIN, 1, 1, 1, true)
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(VERDE .. "Clic: crear la lista de la compra en Auctionator" .. FIN)
    GameTooltip:Show()
end

local function AlEntrarFila(fila)
    local x = fila.dato
    if not x or not GameTooltip then return end
    if estado.modo == "fabricar" then
        TooltipReceta(fila, x.r, x.conocida)
    elseif x.id or x.item then
        GameTooltip:SetOwner(fila, "ANCHOR_RIGHT")
        if GameTooltip.SetItemByID then GameTooltip:SetItemByID(x.id or x.item) end
        GameTooltip:Show()
    end
end

local function AlPulsarFila(fila)
    local x = fila.dato
    if x and estado.modo == "fabricar" then PedirVecesYCrearLista(x.r) end
end

local function AplicarColumnas()
    local defs = COLUMNAS[estado.modo]
    local x = 18
    for i = 1, NUM_COLUMNAS do
        local d = defs[i]
        local cab = ventana.cabeceras[i]
        if d then
            cab:ClearAllPoints()
            cab:SetPoint("TOPLEFT", ventana, "TOPLEFT", x, -106)
            cab:SetWidth(d[2])
            cab:SetJustifyH(d[3])
            cab:SetText(d[1])
            cab:Show()
            for _, fila in ipairs(ventana.filas) do
                local t = fila.c[i]
                t:ClearAllPoints()
                t:SetPoint("LEFT", fila, "LEFT", x - 14, 0)
                t:SetWidth(d[2])
                t:SetJustifyH(d[3])
                t:Show()
            end
            x = x + d[2] + 6
        else
            cab:Hide()
            for _, fila in ipairs(ventana.filas) do fila.c[i]:Hide() end
        end
    end
end

local function Refrescar()
    if not ventana or not ventana:IsShown() then return end
    AplicarColumnas()
    local modo = estado.modo
    for nombre, b in pairs(ventana.pestanas) do
        b:SetEnabled(nombre ~= modo)
    end
    for _, b in ipairs(ventana.botonesFabricar) do
        if modo == "fabricar" then b:Show() else b:Hide() end
    end
    if modo == "cuentas" then ventana.botonPeriodo:Show() else ventana.botonPeriodo:Hide() end

    local info, pie = "", ""
    if modo == "fabricar" then
        lista = ListaFabricar()
        ventana.botonProf:SetText("Profesión: " .. TextoProfesion(estado.prof))
        ventana.botonOrden:SetText(estado.orden == "dia" and "Orden: beneficio x ventas" or "Orden: por unidad")
        ventana.botonVenta:SetText("Solo lo que se vende: " .. (estado.soloVenta and "sí" or "no"))
        ventana.botonConocidas:SetText("Solo las que conozco: " .. (estado.soloConocidas and "sí" or "no"))
        local edad = HorasDesde(D.generadoTs)
        local aviso = ""
        if edad and edad > 6 then
            aviso = ROJO .. string.format("  ¡Datos de hace %.0f h! Revisa la actualización del PC.", edad) .. FIN
        end
        info = string.format("Datos de la subasta: %s · historial: %.1f días%s", D.ultimaDescarga or "?", D.dias or 0, aviso)
        pie = "Clic en una receta: lista de la compra · " .. ResumenMercado()
    elseif modo == "vender" then
        local total
        lista, total = ListaVender()
        info = "Lo que llevas en las bolsas (sin ligados) se puede vender por unos " .. Moneda(total) ..
            GRIS .. " · precios del " .. (D.ultimaDescarga or "?") .. FIN
        pie = "\"Se vende\": probabilidad de venta a ese precio (aparece con unos días de historial). " .. ResumenMercado()
    else
        local tot
        lista, tot = ResumenCuentas(estado.periodo)
        ventana.botonPeriodo:SetText(estado.periodo and ("Periodo: " .. estado.periodo .. " días") or "Periodo: todo")
        local oro = GetMoney and GetMoney() or 0
        local oro7 = OroHaceDias(7)
        local cambio = oro7 and (GRIS .. " (7 días: " .. FIN .. Moneda(oro - oro7) .. GRIS .. ")" .. FIN) or ""
        info = string.format("Ventas %s · Compras %s · Balance %s · Tu oro: %s%s",
            Moneda(tot.ventas), Moneda(tot.compras), Moneda(tot.ventas - tot.compras), Moneda(oro), cambio)
        pie = "Se registran tus ventas y compras al abrir el buzón, y tus compras y publicaciones en la subasta."
    end

    if estado.offset > math.max(0, #lista - VISIBLES) then estado.offset = math.max(0, #lista - VISIBLES) end
    for i = 1, VISIBLES do
        local fila = ventana.filas[i]
        local x = lista[estado.offset + i]
        fila.dato = x
        local c = fila.c
        if not x then
            fila:Hide()
        elseif modo == "fabricar" then
            local r = x.r
            local nombre = (x.conocida and BLANCO or GRIS) .. r[R_NOMBRE] .. FIN
            if r[R_FALTA] then nombre = nombre .. ROJO .. " *" .. FIN end
            local di = D.i and D.i[r[R_ITEM]]
            c[1]:SetText(nombre)
            c[2]:SetText(GRIS .. (D.p[r[R_PROF]] or "") .. FIN)
            c[3]:SetText(Moneda(r[R_BENEF]))
            c[4]:SetText(Ventas(r[R_VD]))
            c[5]:SetText(TendenciaCorta(di and di[I_T7]))
            c[6]:SetText(Moneda(r[R_COSTE]))
            c[7]:SetText(Moneda(r[R_VENTA]))
            fila:Show()
        elseif modo == "vender" then
            local d = D.i and D.i[x.id]
            local colores = { ya = VERDE, hora = AMARILLO, espera = NARANJA, vendedor = BLANCO, nosevende = ROJO }
            c[1]:SetText(BLANCO .. NombreObjeto(x.id) .. FIN)
            c[2]:SetText(tostring(x.cant))
            c[3]:SetText(Moneda(x.c.precio))
            c[4]:SetText(x.c.prob and (x.c.prob .. "%") or (GRIS .. "-" .. FIN))
            c[5]:SetText(Moneda(x.total))
            c[6]:SetText(Ventas(d and d[I_VD]))
            c[7]:SetText((colores[x.c.accion] or "") .. x.c.texto .. FIN)
            fila:Show()
        else
            c[1]:SetText(BLANCO .. (x.n or NombreObjeto(x.item)) .. FIN)
            c[2]:SetText(x.publ > 0 and string.format("%d de %d", x.vend, x.publ) or tostring(x.vend))
            c[3]:SetText(Moneda(x.ingresos))
            c[4]:SetText(tostring(x.comp))
            c[5]:SetText(Moneda(x.gastos))
            c[6]:SetText(Moneda(x.balance))
            c[7]:SetText(x.ultima and date and date("%d/%m %H:%M", x.ultima) or (GRIS .. "-" .. FIN))
            fila:Show()
        end
    end
    ventana.info:SetText(info)
    local desde = #lista > 0 and (estado.offset + 1) or 0
    ventana.pie:SetText(string.format("%d-%d de %d · rueda del ratón para desplazarte · %s",
        desde, math.min(estado.offset + VISIBLES, #lista), #lista, pie))
end
FS.Refrescar = Refrescar

function FS.RefrescarSiCuentas()
    if ventana and ventana:IsShown() and estado.modo == "cuentas" then Refrescar() end
end

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

local function CambiarModo(modo)
    estado.modo = modo
    estado.offset = 0
    Refrescar()
end

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
    f:SetSize(740, 530)
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
    titulo:SetText("Forever Subastas")

    -- Pestañas
    f.pestanas = {}
    local anterior
    for _, p in ipairs({ { "fabricar", "Qué fabricar" }, { "vender", "Qué vender" }, { "cuentas", "Mis cuentas" } }) do
        local b = CrearBoton(f, 120, function() CambiarModo(p[1]) end)
        b:SetText(p[2])
        if anterior then b:SetPoint("LEFT", anterior, "RIGHT", 4, 0) else b:SetPoint("TOPLEFT", 14, -28) end
        f.pestanas[p[1]] = b
        anterior = b
    end

    f.info = Texto(f, "GameFontHighlightSmall", 710)
    f.info:SetPoint("TOPLEFT", 16, -56)

    -- Filtros de "Qué fabricar"
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
    f.botonProf:SetPoint("TOPLEFT", 14, -74)
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
    f.botonesFabricar = { f.botonProf, f.botonOrden, f.botonVenta, f.botonConocidas }

    -- Filtro de "Mis cuentas"
    f.botonPeriodo = CrearBoton(f, 160, function()
        if estado.periodo == 7 then estado.periodo = 30 elseif estado.periodo == 30 then estado.periodo = nil else estado.periodo = 7 end
        estado.offset = 0
        Refrescar()
    end)
    f.botonPeriodo:SetPoint("TOPLEFT", 14, -74)

    f.cabeceras = {}
    for i = 1, NUM_COLUMNAS do
        f.cabeceras[i] = Texto(f, "GameFontNormalSmall", 80)
    end

    f.filas = {}
    for i = 1, VISIBLES do
        local fila = CreateFrame("Button", nil, f)
        fila:SetSize(710, ALTO_FILA)
        fila:SetPoint("TOPLEFT", 14, -122 - (i - 1) * ALTO_FILA)
        local resalte = fila:CreateTexture(nil, "HIGHLIGHT")
        resalte:SetAllPoints()
        resalte:SetColorTexture(1, 1, 1, 0.08)
        if i % 2 == 0 then
            local fondo = fila:CreateTexture(nil, "BACKGROUND")
            fondo:SetAllPoints()
            fondo:SetColorTexture(1, 1, 1, 0.03)
        end
        fila.c = {}
        for k = 1, NUM_COLUMNAS do
            fila.c[k] = Texto(fila, "GameFontHighlightSmall", 80)
        end
        fila:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        fila:SetScript("OnEnter", AlEntrarFila)
        fila:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
        fila:SetScript("OnClick", AlPulsarFila)
        f.filas[i] = fila
    end

    f.pie = Texto(f, "GameFontHighlightSmall", 710)
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

function FS.Mostrar(profesion, modo)
    if not D then
        Imprimir("no encuentro los datos (falta Datos.lua).")
        return
    end
    ventana = ventana or CrearVentana()
    if profesion then
        estado.prof = profesion
        estado.offset = 0
    end
    if modo then
        estado.modo = modo
        estado.offset = 0
    end
    if ventana:IsShown() and not profesion and not modo then
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
        BotonEn(ProfessionsFrame, "Rentabilidad", function() FS.Mostrar(ProfesionAbierta() or "mias", "fabricar") end)
    elseif TradeSkillFrame then
        BotonEn(TradeSkillFrame, "Rentabilidad", function() FS.Mostrar(ProfesionAbierta() or "mias", "fabricar") end)
    end
    if AuctionHouseFrame then
        BotonEn(AuctionHouseFrame, "Qué vender", function() FS.Mostrar(nil, "vender") end)
    end
end

---------------------------------------------------------------------------
-- Eventos y comandos
---------------------------------------------------------------------------

local eventos = CreateFrame("Frame")
for _, ev in ipairs({ "PLAYER_LOGIN", "PLAYER_LOGOUT", "PLAYER_MONEY", "SKILL_LINES_CHANGED", "TRADE_SKILL_SHOW",
    "TRADE_SKILL_LIST_UPDATE", "ADDON_LOADED", "MAIL_INBOX_UPDATE", "AUCTION_HOUSE_SHOW", "BAG_UPDATE_DELAYED",
    "COMMODITY_PRICE_UPDATED", "COMMODITY_PURCHASE_SUCCEEDED", "COMMODITY_PURCHASE_FAILED" }) do
    local ok = pcall(eventos.RegisterEvent, eventos, ev)
    if ok and ev == "COMMODITY_PURCHASE_SUCCEEDED" then eventoCompraOk = true end
end
eventos:SetScript("OnEvent", function(_, evento, arg1, arg2)
    if evento == "PLAYER_LOGIN" then
        D = ForeverSubastasDatos
        pcall(ActualizarProfesiones)
        pcall(EngancharTooltips)
        pcall(EngancharSubasta)
        pcall(CrearBotonesExternos)
        pcall(GuardarOro)
        if D then
            local edad = HorasDesde(D.generadoTs)
            local texto = "datos de la subasta del " .. (D.ultimaDescarga or "?") .. ". Escribe /subastas para abrir la ventana."
            if edad and edad > 6 then
                texto = texto .. ROJO .. string.format(" Ojo: los datos tienen %.0f h.", edad) .. FIN
            end
            Imprimir(texto)
        else
            Imprimir("no encuentro Datos.lua.")
        end
    elseif evento == "PLAYER_MONEY" or evento == "PLAYER_LOGOUT" then
        pcall(GuardarOro)
    elseif evento == "SKILL_LINES_CHANGED" then
        pcall(ActualizarProfesiones)
    elseif evento == "TRADE_SKILL_SHOW" or evento == "TRADE_SKILL_LIST_UPDATE" then
        pcall(LeerRecetasConocidas)
        pcall(CrearBotonesExternos)
    elseif evento == "MAIL_INBOX_UPDATE" then
        pcall(LeerFacturas)
    elseif evento == "AUCTION_HOUSE_SHOW" then
        pcall(EngancharSubasta)
        pcall(CrearBotonesExternos)
    elseif evento == "COMMODITY_PRICE_UPDATED" then
        ultimoTotalCompra = arg2
        if compraPendiente then compraPendiente.total = arg2 end
    elseif evento == "COMMODITY_PURCHASE_SUCCEEDED" then
        if compraPendiente then
            Anotar("compra", compraPendiente.item, nil, compraPendiente.cant, compraPendiente.total or 0)
            compraPendiente = nil
        end
    elseif evento == "COMMODITY_PURCHASE_FAILED" then
        compraPendiente = nil
    elseif evento == "BAG_UPDATE_DELAYED" then
        if ventana and ventana:IsShown() and estado.modo == "vender" then pcall(Refrescar) end
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
        Imprimir("/subastas abre la ventana (qué fabricar, qué vender y tus cuentas). /subastas vender y /subastas cuentas van directos a esas pestañas. Pasa el ratón por cualquier objeto para ver precios, tendencia, mejores horas y a cuánto venderlo. Abre tus profesiones una vez para que sepa qué recetas conoces.")
    elseif texto == "vender" then
        FS.Mostrar(nil, "vender")
    elseif texto == "cuentas" then
        FS.Mostrar(nil, "cuentas")
    elseif texto == "todas" then
        FS.Mostrar("todas", "fabricar")
    else
        FS.Mostrar()
    end
end
