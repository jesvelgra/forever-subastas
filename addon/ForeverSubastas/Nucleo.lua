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
local I_VEND, I_CHOLLO = 21, 22
-- Posiciones dentro de cada receta de D.r
local R_PROF, R_NOMBRE, R_ITEM, R_COSTE, R_VENTA, R_BENEF, R_VD, R_DONDE, R_REAG, R_FALTA = 2, 3, 4, 6, 7, 8, 9, 10, 11, 12
local R_PATRON, R_NIVEL = 13, 14

local MAX_OPERACIONES = 5000

-- Color de las recetas (Enum.TradeskillRelativeDifficulty): 0 naranja, 1 amarilla, 2 verde, 3 gris.
-- Probabilidad media de subir un punto con cada color (fórmula clásica: amarilla 100-50 %, verde 50-0 %).
local DIF_PROB = { [0] = 1, [1] = 0.75, [2] = 0.25, [3] = 0 }
local DIF_COLOR = { [0] = "|cffff8040", [1] = "|cffffff00", [2] = "|cff40c040", [3] = "|cff808080" }
local DIF_NOMBRE = { [0] = "naranja", [1] = "amarilla", [2] = "verde", [3] = "gris" }

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

-- Para las columnas de la ventana: sin cobre a partir de 1 oro y solo oro a partir de 100.
local function MonedaCorta(cobre)
    if cobre == nil then return Moneda(nil) end
    local abs = math.abs(cobre)
    local signo = cobre < 0 and -1 or 1
    if abs >= 1000000 then
        abs = math.floor(abs / 10000 + 0.5) * 10000
    elseif abs >= 10000 then
        abs = math.floor(abs / 100 + 0.5) * 100
    end
    return Moneda(signo * abs)
end

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

-- "1d 20h", "5h 12m", "12m"
local function TiempoCorto(seg)
    seg = math.max(0, math.floor(seg or 0))
    local d, h, m = math.floor(seg / 86400), math.floor(seg % 86400 / 3600), math.floor(seg % 3600 / 60)
    if d > 0 then return string.format("%dd %dh", d, h) end
    if h > 0 then return string.format("%dh %dm", h, m) end
    return string.format("%dm", math.max(m, 1))
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

-- Lo que paga el vendedor por una unidad: de los datos de la API o, si no, del juego.
local function PagaVendedor(id)
    local d = D and D.i and D.i[id]
    return (d and d[I_VEND]) or PrecioVendedor(id)
end
FS.PagaVendedor = PagaVendedor

-- Precios "en vivo": los que ve el addon cuando escaneas la subasta (con Auctionator o a mano).
-- vivo.items[id] = { min, cant, bajo (uds. por debajo del vendedor), coste, valor (lo que pagaría el vendedor), t }
local vivo = { t = 0, items = {} }
FS.vivo = vivo

local function MinimoActual(id)
    local v = vivo.items[id]
    local d = D and D.i and D.i[id]
    local tDatos = D and (D.ultimaDescargaTs or D.generadoTs) or 0
    if v and v.t and v.t > tDatos and v.min then return v.min, "vivo", v end
    return d and d[I_MIN], "datos", nil
end
FS.MinimoActual = MinimoActual

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
    if tipo == "compra" and item and cant and cant > 0 and total and total > 0 then
        local pv = PagaVendedor(item)
        if pv and total / cant < pv * 0.98 then
            cu.chollos = cu.chollos or {}
            cu.chollos[item] = (cu.chollos[item] or 0) + cant
        end
    end
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

local function ProfesionAbierta()
    local T = C_TradeSkillUI
    if T and T.GetBaseProfessionInfo then
        local ok, info = pcall(T.GetBaseProfessionInfo)
        if ok and info and info.professionID and D and D.p[info.professionID] then return info.professionID, info end
    end
    if T and T.GetTradeSkillLine then
        local ok, linea, _, nivel = pcall(T.GetTradeSkillLine)
        if ok and linea and D and D.p[linea] then return linea, { skillLevel = nivel } end
    end
    return nil
end

local function Dificultad(info)
    local d = info.relativeDifficulty
    if type(d) == "number" then return d end
    local t = info.difficulty
    if t == "optimal" then return 0 elseif t == "medium" then return 1 elseif t == "easy" then return 2
    elseif t == "trivial" then return 3 end
    return nil
end

---------------------------------------------------------------------------
-- Enfriamientos de fabricación (Tela lunar, transmutaciones...)
---------------------------------------------------------------------------

-- Horas de enfriamiento en Forever, por objeto fabricado. Sirven para saber que la receta tiene
-- enfriamiento aunque esté lista y para calcular cuándo vuelve si fabricas con la ventana cerrada.
-- Lo que diga el juego al abrir la profesión manda sobre esta tabla.
local CD_HORAS = {
    [14342] = 95,                                   -- Tela lunar
    [12360] = 47, [251290] = 47,                    -- Transmutar: arcanita, legionita
    [7078] = 23, [7080] = 23, [7082] = 23, [7076] = 23, [12803] = 23, [12808] = 23,  -- esencias
    [3577] = 1, [6037] = 1,                         -- Transmutar: hierro a oro, mitril a veraplata
}
local CD_AVISO_HORAS = 20   -- solo se avisa de los enfriamientos largos (los de 1 h serían ruido)

local function Enfriamientos(pj)
    pj.cd = pj.cd or {}
    return pj.cd
end

local function RegistrarEnfriamiento(pj, T, rid, item, nombre, prof)
    if not (T.GetRecipeCooldown and item) then return end
    local ok, resto = pcall(T.GetRecipeCooldown, rid)
    if not ok then return end
    resto = type(resto) == "number" and resto or 0
    local cds = Enfriamientos(pj)
    local e = cds[item]
    if resto <= 0 and not e and not CD_HORAS[item] then return end
    local ahora = time and time() or 0
    e = e or {}
    e.nombre, e.prof, e.rid = nombre or e.nombre, prof or e.prof, rid
    e.h = e.h or CD_HORAS[item]
    -- Recién fabricado: lo que queda es casi la duración completa (así aprende enfriamientos que no están en la tabla).
    if resto > 0 and e.hecho and ahora - e.hecho < 600 then
        e.h = math.floor((resto + (ahora - e.hecho)) / 3600 + 0.5)
    end
    if resto > 0 then
        e.fin = ahora + resto
    elseif not e.fin or e.fin > ahora then
        e.fin = ahora
    end
    -- Si está lista y tienes la ventana abierta, ya lo estás viendo: no hace falta avisar en el chat.
    if resto <= 0 then e.avisado = e.fin end
    cds[item] = e
end

local function LeerRecetasConocidas()
    local T = C_TradeSkillUI
    if not (T and T.GetAllRecipeIDs and T.GetRecipeInfo) then return end
    if T.IsTradeSkillLinked and T.IsTradeSkillLinked() then return end
    if T.IsTradeSkillGuild and T.IsTradeSkillGuild() then return end
    if T.IsNPCCrafting and T.IsNPCCrafting() then return end
    local pj = Personaje()
    local prof, infoProf = ProfesionAbierta()
    local colores = { items = {}, nombres = {} }
    -- Al cambiar de profesión con la ventana abierta, el juego puede dar la lista nueva con el nombre de la
    -- anterior: se comprueba con las recetas de los datos a qué profesión pertenece de verdad lo leído.
    local votos, pendientesCd = {}, {}
    local porProducto = FS.Indices and FS.Indices() or {}
    for _, rid in ipairs(T.GetAllRecipeIDs() or {}) do
        local info = T.GetRecipeInfo(rid)
        if info then
            local item
            if T.GetRecipeOutputItemData then
                local ok, salida = pcall(T.GetRecipeOutputItemData, rid)
                if ok and type(salida) == "table" then item = salida.itemID end
            end
            if not item and T.GetRecipeItemLink then
                local ok, enlace = pcall(T.GetRecipeItemLink, rid)
                if ok and enlace and GetItemInfoInstant then item = GetItemInfoInstant(enlace) end
            end
            if info.learned then
                if item then pj.conocidas[item] = true end
                if info.name then pj.nombres[info.name] = true end
                table.insert(pendientesCd, { rid, item, info.name })
            end
            for _, r in ipairs(item and porProducto[item] or {}) do
                votos[r[R_PROF]] = (votos[r[R_PROF]] or 0) + 1
            end
            local dif = Dificultad(info)
            if dif then
                local dato = { d = dif, a = info.learned and true or false, s = info.numSkillUps or 1, rid = rid }
                if type(info.maxTrivialLevel) == "number" and info.maxTrivialLevel > 0 then dato.g = info.maxTrivialLevel end
                -- Herramientas o puestos necesarios (rueca, telar, yunque...).
                if T.GetRecipeRequirements then
                    local ok, reqs = pcall(T.GetRecipeRequirements, rid)
                    if ok and type(reqs) == "table" and #reqs > 0 then
                        local nombres, cumple = {}, true
                        for _, rq in ipairs(reqs) do
                            if rq.name then table.insert(nombres, rq.name) end
                            if rq.met == false then cumple = false end
                        end
                        if #nombres > 0 then
                            dato.req = table.concat(nombres, ", ")
                            dato.ok = cumple
                        end
                    end
                end
                -- Dónde se aprende (solo las que no conoce).
                if not info.learned and T.GetRecipeSourceText then
                    local ok, fuente = pcall(T.GetRecipeSourceText, rid)
                    if ok and type(fuente) == "string" and fuente ~= "" then dato.f = fuente end
                end
                if item then colores.items[item] = dato end
                if info.name then colores.nombres[info.name] = dato end
            end
        end
    end
    local mejor
    for p, n in pairs(votos) do
        if not mejor or n > votos[mejor] then mejor = p end
    end
    if mejor and mejor ~= prof and votos[mejor] >= 3 and (votos[prof] or 0) * 2 < votos[mejor] then
        prof, infoProf = mejor, nil
    end
    for _, x in ipairs(pendientesCd) do
        RegistrarEnfriamiento(pj, T, x[1], x[2], x[3], prof)
    end
    if prof and next(colores.nombres) then
        pj.subir = pj.subir or {}
        colores.t = time and time() or 0
        colores.nivel = (infoProf and infoProf.skillLevel) or pj.profs[prof]
        colores.max = infoProf and infoProf.maxSkillLevel
        pj.subir[prof] = colores
        if FS.ComprobarSubiendo then FS.ComprobarSubiendo(prof, colores) end
    end
end

local leyendoInstructor = false
local function LeerInstructor()
    if leyendoInstructor or not (GetNumTrainerServices and GetTrainerServiceInfo) then return end
    leyendoInstructor = true
    local _, db = Personaje()
    db.aprender = db.aprender or {}
    local npc = UnitName and UnitName("npc") or "instructor"
    local zona = GetZoneText and GetZoneText() or ""
    local sub = GetSubZoneText and GetSubZoneText() or ""
    if sub ~= "" and sub ~= zona then zona = sub .. ", " .. zona end
    local n = 0
    for i = 1, GetNumTrainerServices() or 0 do
        local nombre, _, tipo = GetTrainerServiceInfo(i)
        if nombre and tipo ~= "header" then
            local nivel
            if GetTrainerServiceSkillReq then
                local _, niv = GetTrainerServiceSkillReq(i)
                nivel = niv
            end
            local coste = GetTrainerServiceCost and GetTrainerServiceCost(i) or nil
            db.aprender[nombre] = { npc = npc, zona = zona, nivel = nivel, coste = coste, t = time and time() or 0 }
            n = n + 1
        end
    end
    leyendoInstructor = false
    return n
end

local function Conocida(pj, r)
    if pj.conocidas[r[R_ITEM]] then return true end
    -- Por nombre solo si el juego no nos dio los objetos fabricados (hay recetas distintas con el mismo nombre).
    if not next(pj.conocidas) then return pj.nombres[r[R_NOMBRE]] or false end
    return false
end

-- Enfriamiento de una receta conocida: texto ("lista" o el tiempo que falta) y la entrada guardada.
local function EnfriamientoReceta(pj, r)
    local e = pj.cd and pj.cd[r[R_ITEM]]
    if not e or (e.prof and e.prof ~= r[R_PROF] and e.nombre ~= r[R_NOMBRE]) then return nil end
    local resto = (e.fin or 0) - (time and time() or 0)
    if resto <= 0 then return VERDE .. "lista" .. FIN, e end
    return NARANJA .. TiempoCorto(resto) .. FIN, e
end

local function NombreCorto(nombre)
    return ((nombre or "?"):gsub("^Transmutar: ", ""))
end

-- Enfriamientos largos de un personaje, juntando los que se comparten (arcanita y legionita acaban
-- a la vez: el juego les pone el mismo enfriamiento). Devuelve {nombre, fin, entradas} ordenados.
local function GruposEnfriamiento(pj)
    local porClave, grupos = {}, {}
    for item, e in pairs(pj.cd or {}) do
        if (e.h or CD_AVISO_HORAS) >= CD_AVISO_HORAS then
            local clave = tostring(e.prof or 0) .. ":" .. math.floor(e.fin or 0)
            local g = porClave[clave]
            if not g then
                g = { nombres = {}, fin = e.fin or 0, entradas = {} }
                porClave[clave] = g
                table.insert(grupos, g)
            end
            table.insert(g.nombres, e.nombre or NombreObjeto(item))
            table.insert(g.entradas, e)
        end
    end
    for _, g in ipairs(grupos) do
        table.sort(g.nombres)
        if #g.nombres > 1 then
            local cortos = {}
            for i, n in ipairs(g.nombres) do cortos[i] = i == 1 and n or NombreCorto(n) end
            g.nombre = table.concat(cortos, " o ")
        else
            g.nombre = g.nombres[1]
        end
    end
    table.sort(grupos, function(x, y) return x.fin < y.fin end)
    return grupos
end

-- Resumen de los enfriamientos largos de este personaje: "arcanita o legionita lista, Tela lunar 3d 2h".
local function ResumenEnfriamientos(pj)
    local ahora = time and time() or 0
    local partes = {}
    for _, g in ipairs(GruposEnfriamiento(pj)) do
        local resto = g.fin - ahora
        table.insert(partes, NombreCorto(g.nombre) .. " " ..
            (resto <= 0 and (VERDE .. "lista" .. FIN) or (NARANJA .. TiempoCorto(resto) .. FIN)))
    end
    if #partes == 0 then return nil end
    return table.concat(partes, ", ")
end

local function NombrePj(clave)
    return (clave:match("^(.-)%-[^-]*$") or clave)
end

-- Una línea en el chat cuando un enfriamiento largo queda listo (una vez por cada vez que se gasta).
local function AvisarEnfriamientos()
    local _, db = Personaje()
    if db.sinAvisosCd then return end
    local ahora = time and time() or 0
    local listos = {}
    local mio = ClavePersonaje()
    for clave, pj in pairs(db.pj or {}) do
        for _, g in ipairs(GruposEnfriamiento(pj)) do
            local nuevo = false
            for _, e in ipairs(g.entradas) do
                if e.fin and e.fin <= ahora and e.avisado ~= e.fin then
                    e.avisado, nuevo = e.fin, true
                end
            end
            if nuevo then
                table.insert(listos, g.nombre .. (clave ~= mio and (GRIS .. " (" .. NombrePj(clave) .. ")" .. FIN) or ""))
            end
        end
    end
    if #listos > 0 then
        Imprimir("ya puedes fabricar " .. VERDE .. table.concat(listos, ", ") .. FIN ..
            GRIS .. " (/fsub cd para verlos · /fsub avisos para quitar este aviso)" .. FIN)
    end
    return #listos
end
FS.AvisarEnfriamientos = AvisarEnfriamientos

-- Al fabricar con la ventana cerrada (macro), el juego no avisa: se calcula con la duración conocida.
local function AlLanzarHechizo(unidad, hechizo)
    if unidad ~= "player" or not hechizo then return end
    local pj = Personaje()
    local ahora = time and time() or 0
    for _, e in pairs(pj.cd or {}) do
        if e.rid == hechizo then
            e.hecho = ahora
            if e.h then e.fin = ahora + e.h * 3600 end
            if FS.RefrescarSiVisible then FS.RefrescarSiVisible() end
        end
    end
end

local function ListarEnfriamientos()
    local _, db = Personaje()
    local hay = false
    for clave, pj in pairs(db.pj or {}) do
        local ahora = time and time() or 0
        local partes = {}
        for item, e in pairs(pj.cd or {}) do
            local resto = (e.fin or 0) - ahora
            table.insert(partes, { t = e.fin or 0, txt = (e.nombre or NombreObjeto(item)) .. ": " ..
                (resto <= 0 and (VERDE .. "lista" .. FIN) or (NARANJA .. TiempoCorto(resto) .. FIN)) ..
                (e.h and (GRIS .. " (cada " .. e.h .. " h)" .. FIN) or "") })
        end
        if #partes > 0 then
            hay = true
            table.sort(partes, function(a, b) return a.t < b.t end)
            local textos = {}
            for _, x in ipairs(partes) do table.insert(textos, x.txt) end
            Imprimir(AMARILLO .. NombrePj(clave) .. FIN .. " · " .. table.concat(textos, " · "))
        end
    end
    if not hay then
        Imprimir("aún no tengo enfriamientos apuntados: abre una vez la ventana de Alquimia o Sastrería con cada personaje.")
    end
end

---------------------------------------------------------------------------
-- Botón del minimapa: al pasar el ratón enseña los enfriamientos de todos tus personajes
---------------------------------------------------------------------------

local function TooltipMinimapa(boton)
    local _, db = Personaje()
    GameTooltip:SetOwner(boton, "ANCHOR_LEFT")
    GameTooltip:SetText("Forever Subastas")
    local ahora = time and time() or 0
    local filas = {}
    for clave, pj in pairs(db.pj or {}) do
        for _, g in ipairs(GruposEnfriamiento(pj)) do
            table.insert(filas, { fin = g.fin, izq = g.nombre .. GRIS .. "  " .. NombrePj(clave) .. FIN })
        end
    end
    table.sort(filas, function(a, b) return a.fin < b.fin end)
    if #filas > 0 then
        GameTooltip:AddLine("Enfriamientos", 1, 0.82, 0)
        for _, f in ipairs(filas) do
            local resto = f.fin - ahora
            GameTooltip:AddDoubleLine(f.izq, resto <= 0 and "lista" or TiempoCorto(resto), 1, 1, 1,
                resto <= 0 and 0.12 or 1, resto <= 0 and 1 or 0.6, resto <= 0 and 0 or 0.2)
        end
    else
        GameTooltip:AddLine("Abre Alquimia o Sastrería una vez para apuntar tus enfriamientos.", 0.6, 0.6, 0.6, true)
    end
    if D and D.ultimaDescarga then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Datos de la subasta: " .. D.ultimaDescarga, 0.6, 0.6, 0.6)
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Clic: abrir · Clic derecho: Qué vender · Arrastrar: mover", 0.12, 1, 0)
    GameTooltip:Show()
end

local function ColocarEnMinimapa(b, angulo)
    local radio = (Minimap:GetWidth() or 140) / 2 + 5
    b:ClearAllPoints()
    b:SetPoint("CENTER", Minimap, "CENTER", math.cos(math.rad(angulo)) * radio, math.sin(math.rad(angulo)) * radio)
end

local function CrearBotonMinimapa()
    if not Minimap or FS.botonMinimapa then return end
    local _, db = Personaje()
    local b = CreateFrame("Button", "ForeverSubastasBotonMinimapa", Minimap)
    FS.botonMinimapa = b
    b:SetSize(31, 31)
    b:SetFrameStrata("MEDIUM")
    b:SetFrameLevel(8)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:RegisterForDrag("LeftButton")
    b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    local icono = b:CreateTexture(nil, "BACKGROUND")
    icono:SetTexture("Interface\\Icons\\INV_Misc_Coin_01")
    icono:SetSize(20, 20)
    icono:SetPoint("TOPLEFT", 7, -5)
    local borde = b:CreateTexture(nil, "OVERLAY")
    borde:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    borde:SetSize(53, 53)
    borde:SetPoint("TOPLEFT")
    ColocarEnMinimapa(b, db.minimapa or 210)
    b:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function(boton)
            local mx, my = Minimap:GetCenter()
            local cx, cy = GetCursorPosition()
            local escala = Minimap:GetEffectiveScale()
            if not (mx and cx and escala) then return end
            db.minimapa = math.deg(math.atan2(cy / escala - my, cx / escala - mx))
            ColocarEnMinimapa(boton, db.minimapa)
        end)
    end)
    b:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
    b:SetScript("OnClick", function(_, boton)
        if boton == "RightButton" then FS.Mostrar(nil, "vender") else FS.Mostrar() end
    end)
    b:SetScript("OnEnter", TooltipMinimapa)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    if db.sinMinimapa then b:Hide() end
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
FS.Indices = Indices

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
    local minimo = MinimoActual(id)
    local precio = d[I_REC] or minimo or d[I_CMP]
    if d[I_REC] and minimo and minimo < d[I_REC] * 0.9 then precio = minimo end
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
    if d[I_PV] and minimo and minimo < d[I_PV] * 0.85 then
        c.precio = d[I_PV]
        c.accion = "espera"
        c.texto = string.format("Espera: ahora está un %.0f%% por debajo de lo que se paga", (1 - minimo / d[I_PV]) * 100)
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
            local textoCd = Conocida(pj, r) and EnfriamientoReceta(pj, r)
            if textoCd then
                tt:AddDoubleLine(GRIS .. "   tu enfriamiento" .. FIN, textoCd, 1, 1, 1, 1, 1, 1)
            end
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
    local minimo, fuente, v = MinimoActual(id)
    local etiqueta = "Mínimo ahora"
    if fuente == "vivo" then etiqueta = "Mínimo (tu escaneo " .. (date and date("%H:%M", v.t) or "") .. ")" end
    tt:AddDoubleLine(etiqueta, minimo and Moneda(minimo) or (GRIS .. "no hay a la venta" .. FIN), 1, 1, 1, 1, 1, 1)
    local pv = PagaVendedor(id)
    if pv and minimo and minimo < pv * 0.98 then
        tt:AddDoubleLine(VERDE .. "¡Chollo! El vendedor paga " .. FIN .. Moneda(pv),
            VERDE .. "ganas " .. FIN .. Moneda(pv - minimo) .. VERDE .. " por unidad" .. FIN, 1, 1, 1, 1, 1, 1)
    end
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

local sugerencia = { n = 5, texto = "" }
local function PedirVecesYCrearLista(r, n, texto)
    sugerencia.n = n or 5
    sugerencia.texto = texto or ""
    if not (StaticPopupDialogs and StaticPopup_Show) then
        CrearListaCompra(r, sugerencia.n)
        return
    end
    if not StaticPopupDialogs["FOREVERSUBASTAS_LISTA"] then
        StaticPopupDialogs["FOREVERSUBASTAS_LISTA"] = {
            text = "¿Cuántas veces quieres fabricar %s?\n%s\nSe descuenta lo que ya tienes.",
            button1 = "Crear lista",
            button2 = "Cancelar",
            hasEditBox = true,
            maxLetters = 4,
            OnShow = function(self)
                local caja = CajaDeTexto(self)
                if caja then
                    caja:SetText(tostring(sugerencia.n))
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
    local texto2 = sugerencia.texto ~= "" and ("Sugerencia: " .. sugerencia.n .. " (" .. sugerencia.texto .. ")") or ""
    StaticPopup_Show("FOREVERSUBASTAS_LISTA", r[R_NOMBRE], texto2, r)
end

---------------------------------------------------------------------------
-- Registro de operaciones (Mis cuentas)
---------------------------------------------------------------------------

-- La compra en la subasta ya se apunta al confirmarla; luego llega su factura por correo con el mismo
-- importe: no hay que contarla dos veces.
local function CompraYaAnotada(cu, item, nombre, importe, ahora)
    for i = #cu.ops, 1, -1 do
        local op = cu.ops[i]
        if ahora - (op.t or 0) > 3 * 86400 then break end
        if op.tipo == "compra" and not op.fac and op.m == importe and (op.c or 0) > 0
            and ((item and op.item == item) or (nombre and op.n == nombre)) then
            op.fac = true
            return true
        end
    end
    return false
end

-- En Forever las facturas de venta no traen la cantidad: se calcula con el precio al que lo publicaste.
local function CantidadVendida(cu, item, nombre, bruto, hasta)
    if not bruto or bruto <= 0 then return nil end
    for i = #cu.ops, 1, -1 do
        local op = cu.ops[i]
        if op.tipo == "publica" and (op.t or 0) <= hasta and (op.c or 0) > 0 and (op.m or 0) > 0
            and ((item and op.item == item) or (nombre and op.n == nombre)) then
            return math.max(1, math.floor(bruto / (op.m / op.c) + 0.5))
        end
    end
    return nil
end

-- Arregla lo apuntado antes de esta versión: compras contadas dos veces y ventas con cantidad 0.
local function RepararCuentas()
    local cu = Cuentas()
    if cu.reparado then return end
    local limpias = {}
    for i, op in ipairs(cu.ops) do
        local duplicada = false
        if op.tipo == "compra" and (op.c or 0) == 0 then
            for j = math.max(1, i - 40), i - 1 do
                local o = cu.ops[j]
                if o.tipo == "compra" and not o.fac and o.m == op.m and (o.c or 0) > 0 and (op.t or 0) - (o.t or 0) < 3 * 86400
                    and ((op.item and o.item == op.item) or (op.n and o.n == op.n)) then
                    o.fac, duplicada = true, true
                    break
                end
            end
            if not duplicada then op.c = 1 end
        elseif op.tipo == "venta" and (op.c or 0) == 0 then
            op.c = CantidadVendida({ ops = limpias }, op.item, op.n, op.bruto or op.m, op.t or 0) or 0
        end
        if not duplicada then table.insert(limpias, op) end
    end
    cu.ops = limpias
    cu.reparado = 1
end
FS.RepararCuentas = RepararCuentas

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
                local cant = (cantidad and cantidad > 0) and cantidad or nil
                if tipo == "seller" then
                    cant = cant or CantidadVendida(cu, item, nombre, puja, ahora) or 0
                    Anotar("venta", item, nombre, cant, (puja or 0) - (comision or 0))
                    local op = cu.ops[#cu.ops]
                    if op then op.bruto = puja end
                elseif not CompraYaAnotada(cu, item, nombre, puja or 0, ahora) then
                    Anotar("compra", item, nombre, cant or 1, puja or 0)
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
-- Escaneos de la subasta (tuyos o de Auctionator) y chollos por debajo del vendedor
---------------------------------------------------------------------------

local function AnotarVivo(id, unidad, cant, ahora)
    local e = vivo.items[id]
    if not e or e.t ~= ahora then
        e = { min = unidad, cant = 0, bajo = 0, coste = 0, valor = 0, t = ahora }
        vivo.items[id] = e
    end
    if unidad < e.min then e.min = unidad end
    e.cant = e.cant + cant
    local pv = PagaVendedor(id)
    if pv and unidad < pv * 0.98 then
        e.bajo = e.bajo + cant
        e.coste = e.coste + unidad * cant
        e.valor = e.valor + pv * cant
    end
end

local function ContarChollosVivos()
    local n, ganancia = 0, 0
    for _, e in pairs(vivo.items) do
        if e.bajo > 0 and e.t >= vivo.t then
            n = n + 1
            ganancia = ganancia + (e.valor - e.coste)
        end
    end
    return n, ganancia
end

local leyendoReplica, ultimaReplica = false, 0
-- Escaneo completo (el botón de escaneo completo de Auctionator usa esta misma función del juego).
local function LeerEscaneoCompleto()
    local AH = C_AuctionHouse
    if leyendoReplica or not (AH and AH.GetNumReplicateItems and AH.GetReplicateItemInfo) then return end
    local total = AH.GetNumReplicateItems() or 0
    if total == 0 or (time() - ultimaReplica) < 60 then return end
    leyendoReplica = true
    local ahora = time()
    local i = 0
    local function Trozo()
        local fin = math.min(i + 4000, total)
        for k = i, fin - 1 do
            local _, _, cant, _, _, _, _, _, _, compra, _, _, _, _, _, _, id = AH.GetReplicateItemInfo(k)
            if id and compra and compra > 0 and cant and cant > 0 then
                AnotarVivo(id, compra / cant, cant, ahora)
            end
        end
        i = fin
        if i < total and C_Timer and C_Timer.After then
            C_Timer.After(0, Trozo)
            return
        end
        if i < total then return Trozo() end
        vivo.t = ahora
        ultimaReplica = ahora
        leyendoReplica = false
        local n, ganancia = ContarChollosVivos()
        Imprimir(string.format("escaneo completo leído (%d subastas). Precios actualizados. Chollos por debajo del vendedor: %d (ganancia posible %s).",
            total, n, Moneda(ganancia)))
        if FS.RefrescarSiVisible then FS.RefrescarSiVisible() end
    end
    Trozo()
end

-- Búsquedas sueltas (las tuyas o las de Auctionator): actualizan el mínimo de ese objeto.
local function LeerBusquedaBienes(id)
    local AH = C_AuctionHouse
    if not (id and AH and AH.GetNumCommoditySearchResults) then return end
    local n = AH.GetNumCommoditySearchResults(id) or 0
    if n == 0 then return end
    local ahora = time()
    vivo.items[id] = nil
    for k = 1, n do
        local r = AH.GetCommoditySearchResultInfo(id, k)
        if r and r.unitPrice and r.quantity then AnotarVivo(id, r.unitPrice, r.quantity, ahora) end
    end
end

local function LeerBusquedaObjetos(clave)
    local AH = C_AuctionHouse
    if not (clave and clave.itemID and AH and AH.GetNumItemSearchResults) then return end
    local n = AH.GetNumItemSearchResults(clave) or 0
    if n == 0 then return end
    local ahora = time()
    vivo.items[clave.itemID] = nil
    for k = 1, n do
        local r = AH.GetItemSearchResultInfo(clave, k)
        if r and r.buyoutAmount and r.buyoutAmount > 0 then
            local cant = r.quantity or 1
            AnotarVivo(clave.itemID, r.buyoutAmount / cant, cant, ahora)
        end
    end
end

-- Lista de chollos: del último escaneo en vivo si es reciente; si no, de los datos horarios.
local function ListaChollos()
    local salida = {}
    local hayVivo = vivo.t > 0 and (time() - vivo.t) < 3600 and vivo.t > (D.ultimaDescargaTs or 0)
    if hayVivo then
        for id, e in pairs(vivo.items) do
            if e.bajo > 0 and e.t >= vivo.t then
                local pv = PagaVendedor(id)
                table.insert(salida, { id = id, uds = e.bajo, min = e.min, pv = pv, ganancia = e.valor - e.coste,
                    porUd = pv and (pv - e.min) or 0 })
            end
        end
    else
        for id, d in pairs(D.i or {}) do
            local pv, minimo = d[I_VEND], d[I_MIN]
            if pv and minimo and minimo < pv * 0.98 then
                table.insert(salida, { id = id, uds = nil, min = minimo, pv = pv, ganancia = pv - minimo, porUd = pv - minimo })
            end
        end
    end
    table.sort(salida, function(x, y) return x.ganancia > y.ganancia end)
    -- Pedir al juego los nombres que aún no tiene (llegan al momento y se refresca la ventana).
    for k = 1, math.min(#salida, 40) do
        local id = salida[k].id
        if C_Item and C_Item.RequestLoadItemDataByID and not (C_Item.GetItemNameByID and C_Item.GetItemNameByID(id)) then
            pcall(C_Item.RequestLoadItemDataByID, id)
        end
    end
    return salida, hayVivo
end

-- Lista de Auctionator con precio máximo = lo que paga el vendedor menos 1 cobre:
-- al buscarla solo salen las subastas que dejan ganancia.
local function ListaAuctionatorChollos(elementos, nombreLista)
    local api = Auctionator and Auctionator.API and Auctionator.API.v1
    if not (api and api.ConvertToSearchString and api.CreateShoppingList) then
        Imprimir("no encuentro Auctionator para crear la lista.")
        return
    end
    local cadenas, sinNombre = {}, 0
    for _, x in ipairs(elementos) do
        local nombre = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(x.id) or (D.n and D.n[x.id])
        if nombre and x.pv then
            local ok, cadena = pcall(api.ConvertToSearchString, "ForeverSubastas",
                { searchString = nombre, isExact = true, maxPrice = math.max(1, math.floor(x.pv * 0.98)) })
            if ok and cadena then table.insert(cadenas, cadena) end
        else
            sinNombre = sinNombre + 1
        end
    end
    if #cadenas == 0 then
        Imprimir("aún no tengo los nombres de esos objetos; vuelve a pulsar en un par de segundos.")
        return
    end
    if api.DeleteShoppingList then pcall(api.DeleteShoppingList, "ForeverSubastas", nombreLista) end
    if pcall(api.CreateShoppingList, "ForeverSubastas", nombreLista, cadenas) then
        Imprimir(string.format("lista \"%s\" creada en Auctionator con %d objetos. Búscala en su pestaña de compras: " ..
            "solo saldrán las subastas por debajo de lo que paga el vendedor.%s", nombreLista, #cadenas,
            sinNombre > 0 and string.format(" (%d sin nombre todavía; vuelve a crearla en un momento)", sinNombre) or ""))
    end
end
FS.ListaAuctionatorChollos = ListaAuctionatorChollos

-- Vender al vendedor lo que compraste por debajo de su precio (un clic en la ventana del vendedor).
local function VenderChollos()
    -- Solo con la ventana del vendedor abierta: si no, "usar" un objeto lo equiparía o lo consumiría.
    if not (MerchantFrame and MerchantFrame:IsShown()) then return end
    local cu = Cuentas()
    local pendientes = cu.chollos or {}
    if not next(pendientes) then
        Imprimir("no tienes chollos pendientes de vender (se apuntan al comprarlos por debajo del vendedor).")
        return
    end
    local C = C_Container
    if not (C and C.GetContainerNumSlots and C.GetContainerItemInfo and C.UseContainerItem) then return end
    local unidades, cobre, mezcladas = 0, 0, 0
    for bolsa = 0, 5 do
        for hueco = 1, C.GetContainerNumSlots(bolsa) or 0 do
            local info = C.GetContainerItemInfo(bolsa, hueco)
            local id = info and info.itemID
            local cant = info and info.stackCount or 1
            -- Solo montones que no superan lo comprado como chollo: no vender lo tuyo que esté mezclado.
            if id and (pendientes[id] or 0) > 0 and cant > pendientes[id] then
                mezcladas = mezcladas + pendientes[id]
            elseif id and (pendientes[id] or 0) > 0 and not info.isLocked and not info.hasNoValue then
                C.UseContainerItem(bolsa, hueco)
                pendientes[id] = math.max(0, pendientes[id] - cant)
                if pendientes[id] == 0 then pendientes[id] = nil end
                unidades = unidades + cant
                local pv = PagaVendedor(id) or 0
                cobre = cobre + pv * cant
                Anotar("venta", id, nil, cant, pv * cant)
            end
        end
    end
    if mezcladas > 0 then
        Imprimir(string.format("%d unidades de chollo están en montones junto con otras tuyas: sepáralas y vuelve a pulsar, o véndelas a mano.", mezcladas))
    end
    if unidades > 0 then
        Imprimir(string.format("vendidas %d unidades compradas como chollo por %s.", unidades, Moneda(cobre)))
    elseif mezcladas == 0 then
        Imprimir("no llevas encima los chollos pendientes (¿siguen en el buzón?).")
    end
end
FS.VenderChollos = VenderChollos

---------------------------------------------------------------------------
-- Ventana: pestañas "Qué fabricar", "Qué vender" y "Mis cuentas"
---------------------------------------------------------------------------

local VISIBLES = 16
local ALTO_FILA = 20
local NUM_COLUMNAS = 7
local estado = { modo = "fabricar", prof = "mias", orden = "unidad", soloVenta = true, soloConocidas = false,
    offset = 0, periodo = 7, profSubir = nil }
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
    subir = {
        { "Receta", 185, "LEFT" }, { "Color", 72, "LEFT" }, { "Coste", 75, "RIGHT" }, { "Recuperas", 80, "RIGHT" },
        { "Coste por punto", 95, "RIGHT" }, { "Ventas/día", 62, "RIGHT" }, { "Aprender", 95, "LEFT" },
    },
    chollos = {
        { "Objeto", 200, "LEFT" }, { "Uds.", 50, "RIGHT" }, { "En subasta", 85, "RIGHT" }, { "Vendedor paga", 90, "RIGHT" },
        { "Ganas/ud", 80, "RIGHT" }, { "Ganancia", 85, "RIGHT" }, { "Visto 7 d", 70, "RIGHT" },
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

local function SinFormato(texto)
    return (texto or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|T.-|t", ""):gsub("|n", " · "):gsub("\n", " · ")
end

---------------------------------------------------------------------------
-- Dónde conseguir patrones y recetas (con QuestieDB, si está instalado)
---------------------------------------------------------------------------

local indicePatrones
-- hechizo de receta -> { objetos que la enseñan }
local function IndicePatrones()
    if indicePatrones ~= nil then return indicePatrones or nil end
    indicePatrones = false
    local IDB = _G.ItemDB
    if not (IDB and IDB.GetAllIds and IDB.teachesSpell and IDB.class) then return nil end
    local ok, ids = pcall(IDB.GetAllIds)
    if not ok or type(ids) ~= "table" then return nil end
    local idx = {}
    for _, id in ipairs(ids) do
        local okc, clase = pcall(IDB.class, id)
        if okc and clase == 9 then
            local okt, hechizo = pcall(IDB.teachesSpell, id)
            if okt and type(hechizo) == "number" then
                idx[hechizo] = idx[hechizo] or {}
                table.insert(idx[hechizo], id)
            end
        end
    end
    indicePatrones = idx
    return idx
end

local function NombreZona(areaId)
    if not areaId then return "?" end
    if C_Map and C_Map.GetAreaInfo then
        local ok, nombre = pcall(C_Map.GetAreaInfo, areaId)
        if ok and nombre then return nombre end
    end
    return "zona " .. areaId
end

-- Nombre, zona y coordenadas (de Forever) de un PNJ, o nil si es de la otra facción.
local function LugarPnj(npc)
    local NDB = _G.NpcDB
    if not NDB then return nil end
    local faccion = UnitFactionGroup and UnitFactionGroup("player")
    local okf, amigo = pcall(NDB.friendlyToFaction, npc)
    if okf and amigo then
        if faccion == "Alliance" and amigo == "H" then return nil end
        if faccion == "Horde" and amigo == "A" then return nil end
    end
    local _, nombre = pcall(NDB.name, npc)
    local areaId, x, y
    local oks, spawns = pcall(NDB.spawns, npc)
    if oks and type(spawns) == "table" then
        for zona, lista in pairs(spawns) do
            if type(lista) == "table" and lista[1] then
                areaId, x, y = zona, lista[1][1], lista[1][2]
                break
            end
        end
    end
    if not areaId then
        local okz, z = pcall(NDB.zoneID, npc)
        if okz then areaId = z end
    end
    if areaId and x and x >= 0 and LibQuestieDB and LibQuestieDB.EraToForever then
        local ok, fx, fy = pcall(LibQuestieDB.EraToForever, areaId, x, y)
        if ok and fx then x, y = fx, fy end
    end
    return { nombre = nombre or ("PNJ " .. npc), zona = NombreZona(areaId), areaId = areaId,
        x = x and x >= 0 and x or nil, y = y and y >= 0 and y or nil }
end

local function TextoLugar(l)
    if l.x then return string.format("%s (%s %.0f, %.0f)", l.nombre, l.zona, l.x, l.y) end
    return l.nombre .. " (" .. l.zona .. ")"
end

-- Vendedores, enemigos que lo sueltan y misiones que lo dan como recompensa.
local function FuentesObjeto(item)
    local IDB = _G.ItemDB
    if not IDB then return nil end
    local f = { vende = {}, suelta = {}, mision = {} }
    local ok, vendedores = pcall(IDB.vendors, item)
    if ok and type(vendedores) == "table" then
        for _, npc in ipairs(vendedores) do
            local l = LugarPnj(npc)
            if l then table.insert(f.vende, l) end
            if #f.vende >= 3 then break end
        end
    end
    local okd, sueltan = pcall(IDB.npcDrops, item)
    if okd and type(sueltan) == "table" then
        for _, npc in ipairs(sueltan) do
            local l = LugarPnj(npc)
            if l then table.insert(f.suelta, l) end
            if #f.suelta >= 3 then break end
        end
        f.totalSuelta = #sueltan
    end
    local okq, misiones = pcall(IDB.questRewards, item)
    if okq and type(misiones) == "table" and _G.QuestDB then
        for _, q in ipairs(misiones) do
            local _, nombre = pcall(_G.QuestDB.name, q)
            table.insert(f.mision, nombre or ("misión " .. q))
            if #f.mision >= 2 then break end
        end
    end
    return f
end

local function MarcarEnMapa(lugar)
    if not (lugar and lugar.x and lugar.areaId and C_Map and C_Map.SetUserWaypoint and UiMapPoint) then return false end
    local mapa
    local ok, zdb = pcall(function() return LibQuestieDB.Support.Get("ZoneDB") end)
    if ok and zdb and zdb.private and zdb.private.areaIdToUiMapId then mapa = zdb.private.areaIdToUiMapId[lugar.areaId] end
    if not mapa then return false end
    local okw = pcall(function()
        C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(mapa, lugar.x / 100, lugar.y / 100))
        if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then C_SuperTrack.SetSuperTrackedUserWaypoint(true) end
    end)
    if okw then Imprimir("marcado en el mapa: " .. TextoLugar(lugar)) end
    return okw
end
FS.MarcarEnMapa = MarcarEnMapa

-- Nivel necesario para aprender una receta, si se sabe (instructor visitado o patrón con requisito).
local function NivelAprender(r)
    local _, db = Personaje()
    local inst = db.aprender and db.aprender[r[R_NOMBRE]]
    return (inst and inst.nivel) or r[R_NIVEL]
end

-- Devuelve: textoCorto, lineasTooltip, nivelNecesario, lugarParaElMapa
local function InfoAprender(r, dato)
    local _, db = Personaje()
    local lineas = {}
    local corto, nivel
    local inst = db.aprender and db.aprender[r[R_NOMBRE]]
    if inst then
        nivel = inst.nivel
        corto = "instructor" .. (inst.coste and inst.coste > 0 and (" " .. MonedaCorta(inst.coste)) or "")
        table.insert(lineas, { "Instructor", inst.npc .. " (" .. inst.zona .. ")" })
        if inst.nivel then table.insert(lineas, { "   Nivel necesario", tostring(inst.nivel) }) end
        if inst.coste then table.insert(lineas, { "   Coste", Moneda(inst.coste) }) end
    end
    local patron = r[R_PATRON]
    if patron then
        nivel = nivel or r[R_NIVEL]
        local dp = D.i and D.i[patron]
        local precio = dp and dp[I_MIN]
        table.insert(lineas, { "Se aprende con", NombreObjeto(patron) })
        if r[R_NIVEL] then table.insert(lineas, { "   Nivel necesario", tostring(r[R_NIVEL]) }) end
        if precio then
            table.insert(lineas, { "   En la subasta desde", Moneda(precio) })
            if not corto then corto = "patrón " .. MonedaCorta(precio) end
        end
    end
    -- Patrones que enseñan la receta: el de nuestros datos y los que conozca QuestieDB.
    local patrones, vistos = {}, {}
    if patron then table.insert(patrones, patron); vistos[patron] = true end
    local idx = dato and dato.rid and IndicePatrones()
    if idx and idx[dato.rid] then
        for _, id in ipairs(idx[dato.rid]) do
            if not vistos[id] then table.insert(patrones, id); vistos[id] = true end
        end
    end
    local lugarMapa
    for k = 1, math.min(2, #patrones) do
        local id = patrones[k]
        if id ~= patron then table.insert(lineas, { "Se aprende con", NombreObjeto(id) }) end
        local f = FuentesObjeto(id)
        if f then
            for _, l in ipairs(f.vende) do
                table.insert(lineas, { "   Lo vende", TextoLugar(l) })
                lugarMapa = lugarMapa or l
            end
            if #f.vende > 0 then corto = "vende " .. f.vende[1].nombre end
            for _, l in ipairs(f.suelta) do table.insert(lineas, { "   Lo suelta", TextoLugar(l) }) end
            if f.totalSuelta and f.totalSuelta > #f.suelta then
                table.insert(lineas, { "   ", string.format("y %d enemigos más", f.totalSuelta - #f.suelta) })
            end
            if #f.suelta > 0 and not corto then corto = "botín" end
            for _, q in ipairs(f.mision) do table.insert(lineas, { "   Recompensa de", q }) end
            if #f.mision > 0 and not corto then corto = "misión" end
        end
    end
    if #patrones == 0 and not inst and not (dato and dato.f) then
        corto = "instructor?"
        table.insert(lineas, { "Sin patrón conocido", "seguramente la enseña el instructor" })
        table.insert(lineas, { GRIS .. "Si en el instructor no aparece, en su ventana abre Configuración y marca \"No disponible\"." .. FIN, "" })
    end
    if dato and dato.f then
        table.insert(lineas, { "Fuente según el juego", SinFormato(dato.f) })
        if not corto then
            local f = SinFormato(dato.f):lower()
            if f:find("instructor") then corto = "instructor"
            elseif f:find("vendedor") then corto = "vendedor"
            elseif f:find("misi") then corto = "misión"
            elseif f:find("bot") or f:find("drop") then corto = "botín"
            else corto = "ver fuente" end
        end
    end
    return corto or "aprender", lineas, nivel, lugarMapa
end

local function NombreRequisito(dato)
    if not (dato and dato.req) then return "" end
    return (dato.ok == false and ROJO or GRIS) .. " [" .. dato.req .. "]" .. FIN
end

-- Cuántas veces fabricar para subir con esta receta hasta que deje de compensar (se vuelva verde).
-- Usa el nivel en que se vuelve gris si el juego lo da; con amarilla, la probabilidad baja de forma lineal.
local function SugerirCantidad(x)
    local nivel = x.nivelProf
    local gris = x.gris
    if x.dif == 0 then
        if gris and nivel then
            -- Naranja: hasta que pase a amarilla no se sabe exactamente; estimamos que la amarilla empieza
            -- unos (gris - amarilla) = 2/3 del tramo restante antes del gris.
            local puntos = math.max(1, math.floor((gris - nivel) / 3))
            return puntos, string.format("naranja: 1 punto por fabricación; unos %d puntos hasta que se vuelva amarilla", puntos)
        end
        return 5, "naranja: 1 punto por fabricación; te aviso cuando cambie de color"
    elseif x.dif == 1 then
        if gris and nivel and gris > nivel then
            local restante = gris - nivel
            local puntos = math.max(1, math.floor(restante / 2))  -- hasta que se vuelva verde
            local veces = 0
            for k = 0, puntos - 1 do veces = veces + restante / (restante - k) end
            veces = math.ceil(veces)
            return veces, string.format("amarilla: unos %d puntos hasta que se vuelva verde (se vuelve gris en %d)", puntos, gris)
        end
        return 7, "amarilla: ~75% de subir; con 7 fabricaciones, unos 5 puntos. Te aviso cuando se vuelva verde"
    end
    return 0, "verde: solo sube 1 de cada 4; mejor otra receta"
end
FS.SugerirCantidad = SugerirCantidad

-- Profesiones de las que hay colores leídos (o que el personaje tiene y fabrican algo).
local function ProfesionesParaSubir()
    local pj = Personaje()
    local vistas, lista = {}, {}
    for prof in pairs(pj.subir or {}) do
        if D.p[prof] and not vistas[prof] then vistas[prof] = true; table.insert(lista, prof) end
    end
    for prof in pairs(pj.profs) do
        if D.p[prof] and not vistas[prof] then vistas[prof] = true; table.insert(lista, prof) end
    end
    table.sort(lista, function(x, y) return (D.p[x] or "") < (D.p[y] or "") end)
    return lista
end

local ocultas = 0
local function ListaSubir()
    local pj = Personaje()
    local profs = ProfesionesParaSubir()
    if not estado.profSubir or not D.p[estado.profSubir] then estado.profSubir = profs[1] end
    local prof = estado.profSubir
    local colores = prof and pj.subir and pj.subir[prof]
    local salida = {}
    ocultas = 0
    if not colores then return salida, prof, nil end
    for _, r in ipairs(D.r or {}) do
        if r[R_PROF] == prof then
            -- Por objeto fabricado; por nombre solo si el juego no dio los objetos (hay recetas con el mismo nombre).
            local c = colores.items[r[R_ITEM]]
            if not c and not next(colores.items) then c = colores.nombres[r[R_NOMBRE]] end
            local nivelReq = NivelAprender(r)
            if c and not c.a and colores.nivel then
                local muyAlta = nivelReq and nivelReq > colores.nivel
                -- Sin nivel conocido: si se vuelve gris más de 60 puntos por encima, casi seguro aún no se puede aprender.
                if not nivelReq and c.g and c.g - colores.nivel > 60 then muyAlta = true end
                if muyAlta then
                    ocultas = ocultas + 1
                    c = nil
                end
            end
            if c and c.d and c.d < 3 then
                -- Lo que recuperas: la venta neta si se vende, si no lo que paga el vendedor.
                local recuperas, donde = r[R_VENTA] or 0, "subasta"
                if r[R_VD] ~= nil and r[R_VD] < 1 then
                    recuperas, donde = (PrecioVendedor(r[R_ITEM]) or 0), "vendedor"
                end
                local prob = DIF_PROB[c.d] * (c.s or 1)
                local porPunto = (r[R_COSTE] - recuperas) / prob
                table.insert(salida, { r = r, dif = c.d, aprendida = c.a, recuperas = recuperas, donde = donde,
                    porPunto = porPunto, prob = DIF_PROB[c.d], conocida = c.a, dato = c, gris = c.g,
                    nivelProf = colores.nivel, prof = prof })
            end
        end
    end
    table.sort(salida, function(x, y)
        local fx, fy = x.r[R_FALTA] and 1 or 0, y.r[R_FALTA] and 1 or 0
        if fx ~= fy then return fx < fy end
        return x.porPunto < y.porPunto
    end)
    return salida, prof, colores
end

function FS.ComprobarSubiendo(prof, colores)
    local sub = FS.subiendo
    if not sub or sub.prof ~= prof then return end
    local c = colores.items[sub.item] or colores.nombres[sub.nombre]
    if not c or c.d == sub.dif then return end
    sub.dif = c.d
    if c.d >= 2 then
        local alternativa = ""
        local anterior = estado.profSubir
        estado.profSubir = prof
        local lista = ListaSubir()
        estado.profSubir = anterior
        for _, x in ipairs(lista) do
            if x.r[R_ITEM] ~= sub.item and x.aprendida and x.dif <= 1 and not x.r[R_FALTA] then
                alternativa = " Ahora te sale mejor: " .. x.r[R_NOMBRE] .. " (" .. Moneda(x.porPunto) .. " por punto)."
                break
            end
        end
        Imprimir(sub.nombre .. " ya está " .. DIF_COLOR[c.d] .. DIF_NOMBRE[c.d] .. FIN ..
            (c.d == 3 and ": ya no da puntos." or ": solo sube 1 de cada 4.") .. alternativa)
    elseif c.d == 1 then
        Imprimir(sub.nombre .. " ha pasado a " .. DIF_COLOR[1] .. "amarilla" .. FIN .. " (75% de subir). Aún compensa.")
    end
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
    local pjr = Personaje()
    local col = pjr.subir and pjr.subir[r[R_PROF]]
    local dato = col and col.items[r[R_ITEM]]
    if dato and dato.req then
        local falta = dato.ok == false
        GameTooltip:AddDoubleLine("Necesitas", dato.req, 1, 1, 1, falta and 1 or 0.6, falta and 0.25 or 1, falta and 0.25 or 0.6)
    end
    local textoVenta = "Venta neta (tras 5% de la subasta)"
    if r[R_DONDE] == "vendedor" then textoVenta = "Venta al vendedor (mejor que la subasta)" end
    if r[R_DONDE] == "mercado" then textoVenta = textoVenta .. GRIS .. " · precio de mercado" .. FIN end
    if r[R_DONDE] == "real" then textoVenta = textoVenta .. VERDE .. " · ventas reales" .. FIN end
    GameTooltip:AddDoubleLine(textoVenta, Moneda(r[R_VENTA]), 1, 1, 1, 1, 1, 1)
    GameTooltip:AddDoubleLine("Beneficio por fabricación", Moneda(r[R_BENEF]), 1, 1, 1, 1, 1, 1)
    local textoCd, e = nil, nil
    if conocida then textoCd, e = EnfriamientoReceta(pjr, r) end
    local horas = (e and e.h) or CD_HORAS[r[R_ITEM]]
    if horas and horas >= 2 then
        GameTooltip:AddDoubleLine("Enfriamiento: cada " .. horas .. " h",
            textoCd and ("tu enfriamiento: " .. textoCd) or "", 1, 1, 1, 1, 1, 1)
        if (r[R_BENEF] or 0) > 0 then
            GameTooltip:AddDoubleLine("Beneficio por día de enfriamiento", Moneda(math.floor(r[R_BENEF] * 24 / horas)),
                1, 1, 1, 1, 1, 1)
        end
    elseif textoCd then
        GameTooltip:AddDoubleLine("Tu enfriamiento", textoCd, 1, 1, 1, 1, 1, 1)
    end
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
    elseif estado.modo == "subir" then
        TooltipReceta(fila, x.r, x.aprendida)
        GameTooltip:AddLine(" ")
        GameTooltip:AddDoubleLine("Color ahora", DIF_COLOR[x.dif] .. DIF_NOMBRE[x.dif] .. FIN ..
            string.format(" (sube un punto el %d%% de las veces)", math.floor(x.prob * 100 + 0.5)), 1, 1, 1, 1, 1, 1)
        GameTooltip:AddDoubleLine("Recuperas al venderlo (" .. x.donde .. ")", Moneda(x.recuperas), 1, 1, 1, 1, 1, 1)
        GameTooltip:AddDoubleLine("Coste neto por punto de habilidad", Moneda(x.porPunto), 1, 1, 1, 1, 1, 1)
        if x.gris then
            GameTooltip:AddDoubleLine("Se vuelve gris en", tostring(x.gris), 1, 1, 1, 1, 1, 1)
        end
        local n, texto = SugerirCantidad(x)
        GameTooltip:AddDoubleLine("Cantidad sugerida", n > 0 and (n .. " veces") or "ninguna", 1, 0.82, 0, 1, 1, 1)
        GameTooltip:AddLine(GRIS .. "   " .. texto .. FIN, 1, 1, 1, true)
        if x.dato and x.dato.req then
            local falta = x.dato.ok == false
            GameTooltip:AddDoubleLine("Necesitas", x.dato.req .. (falta and " (no la tienes cerca)" or ""),
                1, 1, 1, falta and 1 or 0.6, falta and 0.25 or 1, falta and 0.25 or 0.6)
            local idReq = IdPorNombre(x.dato.req)
            local dr = idReq and D.i and D.i[idReq]
            if dr and dr[I_MIN] then
                GameTooltip:AddDoubleLine("   " .. x.dato.req .. " en la subasta desde", Moneda(dr[I_MIN]), 1, 1, 1, 1, 1, 1)
            end
            local pi = Indices()
            local fab = idReq and pi[idReq]
            if fab and fab[1] then
                GameTooltip:AddDoubleLine("   Se fabrica con", (D.p[fab[1][R_PROF]] or "?") .. ": " .. fab[1][R_NOMBRE], 1, 1, 1, 1, 1, 1)
            end
        end
        if not x.aprendida then
            local _, lineas = InfoAprender(x.r, x.dato)
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine(NARANJA .. "Aún no la conoces. Cómo aprenderla:" .. FIN)
            for _, l in ipairs(lineas) do GameTooltip:AddDoubleLine(l[1], l[2], 1, 1, 1, 1, 1, 1) end
            local _, _, _, lugar = InfoAprender(x.r, x.dato)
            if lugar then GameTooltip:AddLine(VERDE .. "Mayúsculas + clic: marcarlo en el mapa" .. FIN) end
            if #lineas == 0 then
                GameTooltip:AddLine(GRIS .. "Visita a tu instructor de " .. (D.p[x.prof] or "la profesión") ..
                    " una vez y el addon apuntará qué enseña, a qué nivel y cuánto cuesta." .. FIN, 1, 1, 1, true)
            end
        end
        GameTooltip:Show()
    elseif x.id or x.item then
        GameTooltip:SetOwner(fila, "ANCHOR_RIGHT")
        if GameTooltip.SetItemByID then GameTooltip:SetItemByID(x.id or x.item) end
        GameTooltip:Show()
    end
end

local function AlPulsarFila(fila)
    local x = fila.dato
    if not x then return end
    if estado.modo == "chollos" then
        ListaAuctionatorChollos({ x }, "FS Chollo " .. NombreObjeto(x.id))
        return
    end
    if estado.modo == "fabricar" then
        PedirVecesYCrearLista(x.r)
    elseif estado.modo == "subir" then
        if IsShiftKeyDown and IsShiftKeyDown() and not x.aprendida then
            local _, _, _, lugar = InfoAprender(x.r, x.dato)
            if not MarcarEnMapa(lugar) then Imprimir("no tengo la posición de quien enseña esta receta.") end
            return
        end
        local n, texto = SugerirCantidad(x)
        FS.subiendo = { prof = x.prof, item = x.r[R_ITEM], nombre = x.r[R_NOMBRE], dif = x.dif }
        PedirVecesYCrearLista(x.r, math.max(1, n), texto)
    end
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
    if modo == "subir" then ventana.botonSubirProf:Show() else ventana.botonSubirProf:Hide() end
    if modo == "chollos" then ventana.botonListaChollos:Show() else ventana.botonListaChollos:Hide() end

    local info, pie = "", ""
    local pjFab = Personaje()
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
        local cds = ResumenEnfriamientos(pjFab)
        if cds then info = info .. " · Enfriamientos: " .. cds end
        pie = "Clic en una receta: lista de la compra · " .. ResumenMercado()
    elseif modo == "subir" then
        local prof, colores
        lista, prof, colores = ListaSubir()
        ventana.botonSubirProf:SetText("Profesión: " .. (prof and D.p[prof] or "ninguna"))
        if not prof then
            info = "No encuentro profesiones de fabricación en este personaje."
        elseif not colores then
            info = NARANJA .. "Abre la ventana de " .. D.p[prof] .. " para que lea el color de tus recetas." .. FIN
        else
            local hace = HorasDesde(colores.t)
            local cuando = hace and (hace < 1 and string.format("hace %d min", math.floor(hace * 60)) or string.format("hace %.0f h", hace)) or "?"
            local mejor = lista[1]
            info = string.format("%s nivel %s · colores leídos %s%s%s", D.p[prof], tostring(colores.nivel or "?"), cuando,
                mejor and (" · lo más barato: " .. mejor.r[R_NOMBRE] .. " a " .. Moneda(mejor.porPunto) .. " por punto") or "",
                ocultas > 0 and (GRIS .. string.format(" · %d ocultas por nivel", ocultas) .. FIN) or "")
        end
        pie = "Clic: lista de la compra con la cantidad sugerida. Visita a tu instructor una vez para saber nivel y coste de lo que enseña."
    elseif modo == "chollos" then
        local hayVivo
        lista, hayVivo = ListaChollos()
        local total = 0
        for _, x in ipairs(lista) do total = total + (x.ganancia or 0) end
        if hayVivo then
            info = string.format("Tu escaneo de las %s: %d objetos por debajo del vendedor, ganancia posible %s.",
                date and date("%H:%M", vivo.t) or "?", #lista, Moneda(total))
        else
            info = string.format("Datos de las %s: %d objetos por debajo del vendedor. " ..
                "Haz un escaneo completo en Auctionator para verlos al momento y con cantidades.", D.ultimaDescarga or "?", #lista)
        end
        pie = "Compra con la lista de Auctionator y luego en cualquier vendedor pulsa 'Vender chollos'. Clic en una fila: lista solo de ese objeto."
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
            local textoCd = x.conocida and EnfriamientoReceta(pjFab, r)
            if textoCd then nombre = nombre .. GRIS .. " · " .. FIN .. textoCd end
            local di = D.i and D.i[r[R_ITEM]]
            c[1]:SetText(nombre)
            c[2]:SetText(GRIS .. (D.p[r[R_PROF]] or "") .. FIN)
            c[3]:SetText(MonedaCorta(r[R_BENEF]))
            c[4]:SetText(Ventas(r[R_VD]))
            c[5]:SetText(TendenciaCorta(di and di[I_T7]))
            c[6]:SetText(MonedaCorta(r[R_COSTE]))
            c[7]:SetText(MonedaCorta(r[R_VENTA]))
            fila:Show()
        elseif modo == "subir" then
            local r = x.r
            local nombre = (x.aprendida and BLANCO or GRIS) .. r[R_NOMBRE] .. FIN .. NombreRequisito(x.dato)
            if r[R_FALTA] then nombre = nombre .. ROJO .. " *" .. FIN end
            c[1]:SetText(nombre)
            c[2]:SetText(DIF_COLOR[x.dif] .. DIF_NOMBRE[x.dif] .. FIN .. GRIS .. string.format(" %d%%", math.floor(x.prob * 100 + 0.5)) .. FIN)
            c[3]:SetText(MonedaCorta(r[R_COSTE]))
            c[4]:SetText(MonedaCorta(x.recuperas))
            c[5]:SetText(x.porPunto <= 0 and (VERDE .. "gana " .. FIN .. MonedaCorta(-x.porPunto)) or MonedaCorta(x.porPunto))
            c[6]:SetText(Ventas(r[R_VD]))
            local corto = x.aprendida and "" or (InfoAprender(r, x.dato))
            c[7]:SetText(x.aprendida and "" or (NARANJA .. corto .. FIN))
            fila:Show()
        elseif modo == "chollos" then
            local d = D.i and D.i[x.id]
            c[1]:SetText(BLANCO .. NombreObjeto(x.id) .. FIN)
            c[2]:SetText(x.uds and tostring(x.uds) or (GRIS .. "?" .. FIN))
            c[3]:SetText(MonedaCorta(x.min))
            c[4]:SetText(MonedaCorta(x.pv))
            c[5]:SetText(VERDE .. FIN .. MonedaCorta(x.porUd))
            c[6]:SetText(x.uds and MonedaCorta(x.ganancia) or (GRIS .. "-" .. FIN))
            local pct = d and d[I_CHOLLO]
            c[7]:SetText(pct and (pct .. "% h") or (GRIS .. "-" .. FIN))
            fila:Show()
        elseif modo == "vender" then
            local d = D.i and D.i[x.id]
            local colores = { ya = VERDE, hora = AMARILLO, espera = NARANJA, vendedor = BLANCO, nosevende = ROJO }
            c[1]:SetText(BLANCO .. NombreObjeto(x.id) .. FIN)
            c[2]:SetText(tostring(x.cant))
            c[3]:SetText(MonedaCorta(x.c.precio))
            c[4]:SetText(x.c.prob and (x.c.prob .. "%") or (GRIS .. "-" .. FIN))
            c[5]:SetText(MonedaCorta(x.total))
            c[6]:SetText(Ventas(d and d[I_VD]))
            c[7]:SetText((colores[x.c.accion] or "") .. x.c.texto .. FIN)
            fila:Show()
        else
            c[1]:SetText(BLANCO .. (x.n or NombreObjeto(x.item)) .. FIN)
            c[2]:SetText(x.publ > 0 and string.format("%d de %d", x.vend, x.publ) or tostring(x.vend))
            c[3]:SetText(MonedaCorta(x.ingresos))
            c[4]:SetText(tostring(x.comp))
            c[5]:SetText(MonedaCorta(x.gastos))
            c[6]:SetText(MonedaCorta(x.balance))
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

function FS.RefrescarSiVisible()
    if ventana and ventana:IsShown() then Refrescar() end
end

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
    for _, p in ipairs({ { "fabricar", "Qué fabricar" }, { "subir", "Subir profesión" }, { "vender", "Qué vender" },
        { "chollos", "Chollos" }, { "cuentas", "Mis cuentas" } }) do
        local b = CrearBoton(f, 116, function() CambiarModo(p[1]) end)
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

    -- Filtro de "Subir profesión"
    f.botonSubirProf = CrearBoton(f, 220, function()
        local profs = ProfesionesParaSubir()
        if #profs == 0 then return end
        local actual = 1
        for i, p in ipairs(profs) do if p == estado.profSubir then actual = i end end
        estado.profSubir = profs[actual % #profs + 1]
        estado.offset = 0
        Refrescar()
    end)
    f.botonSubirProf:SetPoint("TOPLEFT", 14, -74)

    -- Botón de "Chollos"
    f.botonListaChollos = CrearBoton(f, 260, function()
        local l = ListaChollos()
        ListaAuctionatorChollos(l, "FS Chollos vendedor")
    end)
    f.botonListaChollos:SetText("Crear lista de compra en Auctionator")
    f.botonListaChollos:SetPoint("TOPLEFT", 14, -74)

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

local function BotonEn(marco, texto, alClic, clave, desplazamiento, debajo)
    clave = clave or "ForeverSubastasBoton"
    if not marco or marco[clave] then return end
    local ok, b = pcall(CreateFrame, "Button", nil, marco, "UIPanelButtonTemplate")
    if not ok or not b then return end
    b:SetSize(120, 22)
    b:SetText(texto)
    if debajo then
        -- Debajo del marco, a la derecha de sus pestañas (para no tapar los botones de Auctionator).
        b:SetPoint("TOPRIGHT", marco, "BOTTOMRIGHT", -(desplazamiento or 0), -2)
    else
        b:SetPoint("TOPRIGHT", marco, "TOPRIGHT", -30 - (desplazamiento or 0), -26)
    end
    b:SetFrameStrata("HIGH")
    b:SetScript("OnClick", alClic)
    marco[clave] = b
end

-- Botones de la subasta: a la derecha de las pestañas si hay sitio; si las pestañas (de Blizzard,
-- Auctionator u otros addons) llegan hasta esa zona, se bajan por debajo de la fila de pestañas.
-- Las pestañas de Auctionator (LibAHTab) son nietas del marco: cuelgan de un marco intermedio.
function FS.ColocarBotonesSubasta()
    local f = AuctionHouseFrame
    local vender, chollos = f and f.ForeverSubastasBoton, f and f.ForeverSubastasBotonChollos
    if not (vender and chollos) then return end
    local fondo, derecha = f:GetBottom(), f:GetRight()
    local hueco = 0
    local ancho = 2 * 120 + 4 + 8
    local function Revisar(marco, nivel)
        if not marco.GetChildren then return end
        for _, hijo in ipairs({ marco:GetChildren() }) do
            if hijo ~= vender and hijo ~= chollos and hijo.IsShown and hijo:IsShown() then
                local b, t, d = hijo:GetBottom(), hijo:GetTop(), hijo:GetRight()
                -- Lo que cuelga por debajo del marco (las pestañas) y llega a la zona de los botones.
                if b and t and d and b < fondo - 2 and t <= fondo + 12 and (t - b) < 60 and d > derecha - ancho then
                    hueco = math.max(hueco, fondo - b)
                end
                if nivel < 2 then Revisar(hijo, nivel + 1) end
            end
        end
    end
    if fondo and derecha then Revisar(f, 1) end
    vender:ClearAllPoints()
    vender:SetPoint("TOPRIGHT", f, "BOTTOMRIGHT", 0, hueco > 0 and -(hueco + 2) or -2)
    chollos:ClearAllPoints()
    chollos:SetPoint("RIGHT", vender, "LEFT", -4, 0)
end

local function AbrirSubir()
    local prof = ProfesionAbierta()
    if prof then estado.profSubir = prof end
    pcall(LeerRecetasConocidas)
    FS.Mostrar(nil, "subir")
end

local function CrearBotonesExternos()
    local marcoProf = ProfessionsFrame or TradeSkillFrame
    if marcoProf then
        BotonEn(marcoProf, "Rentabilidad", function() FS.Mostrar(ProfesionAbierta() or "mias", "fabricar") end)
        BotonEn(marcoProf, "Subir profesión", AbrirSubir, "ForeverSubastasBotonSubir", 124)
    end
    if AuctionHouseFrame then
        BotonEn(AuctionHouseFrame, "Qué vender", function() FS.Mostrar(nil, "vender") end, nil, 0, true)
        BotonEn(AuctionHouseFrame, "Chollos", function() FS.Mostrar(nil, "chollos") end, "ForeverSubastasBotonChollos", 124, true)
    end
    if MerchantFrame then
        BotonEn(MerchantFrame, "Vender chollos", VenderChollos, "ForeverSubastasBotonVendedor", 0)
    end
end

---------------------------------------------------------------------------
-- Eventos y comandos
---------------------------------------------------------------------------

local eventos = CreateFrame("Frame")
for _, ev in ipairs({ "PLAYER_LOGIN", "PLAYER_LOGOUT", "PLAYER_MONEY", "SKILL_LINES_CHANGED", "TRADE_SKILL_SHOW",
    "TRADE_SKILL_LIST_UPDATE", "ADDON_LOADED", "MAIL_INBOX_UPDATE", "AUCTION_HOUSE_SHOW", "BAG_UPDATE_DELAYED",
    "COMMODITY_PRICE_UPDATED", "COMMODITY_PURCHASE_SUCCEEDED", "COMMODITY_PURCHASE_FAILED", "TRAINER_SHOW",
    "TRAINER_UPDATE", "REPLICATE_ITEM_LIST_UPDATE", "COMMODITY_SEARCH_RESULTS_UPDATED", "ITEM_SEARCH_RESULTS_UPDATED",
    "MERCHANT_SHOW", "GET_ITEM_INFO_RECEIVED" }) do
    local ok = pcall(eventos.RegisterEvent, eventos, ev)
    if ok and ev == "COMMODITY_PURCHASE_SUCCEEDED" then eventoCompraOk = true end
end
if eventos.RegisterUnitEvent then
    pcall(eventos.RegisterUnitEvent, eventos, "UNIT_SPELLCAST_SUCCEEDED", "player")
else
    pcall(eventos.RegisterEvent, eventos, "UNIT_SPELLCAST_SUCCEEDED")
end
eventos:SetScript("OnEvent", function(_, evento, arg1, arg2, arg3)
    if evento == "UNIT_SPELLCAST_SUCCEEDED" then
        pcall(AlLanzarHechizo, arg1, arg3)
    elseif evento == "PLAYER_LOGIN" then
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
        pcall(RepararCuentas)
        pcall(CrearBotonMinimapa)
        pcall(AvisarEnfriamientos)
        -- Y mientras juegas, se mira cada 5 minutos si alguno ha quedado listo.
        if C_Timer and C_Timer.NewTicker then
            C_Timer.NewTicker(300, function() pcall(AvisarEnfriamientos) end)
        end
    elseif evento == "PLAYER_MONEY" or evento == "PLAYER_LOGOUT" then
        pcall(GuardarOro)
    elseif evento == "SKILL_LINES_CHANGED" then
        pcall(ActualizarProfesiones)
    elseif evento == "TRADE_SKILL_SHOW" or evento == "TRADE_SKILL_LIST_UPDATE" then
        pcall(LeerRecetasConocidas)
        pcall(CrearBotonesExternos)
    elseif evento == "TRAINER_SHOW" or evento == "TRAINER_UPDATE" then
        local ok, n = pcall(LeerInstructor)
        if ok and n and n > 0 and evento == "TRAINER_SHOW" then
            Imprimir("apuntado lo que enseña este instructor (" .. n .. " entradas) para la pestaña Subir profesión.")
        end
    elseif evento == "REPLICATE_ITEM_LIST_UPDATE" then
        pcall(LeerEscaneoCompleto)
    elseif evento == "COMMODITY_SEARCH_RESULTS_UPDATED" then
        pcall(LeerBusquedaBienes, arg1)
    elseif evento == "ITEM_SEARCH_RESULTS_UPDATED" then
        pcall(LeerBusquedaObjetos, arg1)
    elseif evento == "MERCHANT_SHOW" then
        pcall(CrearBotonesExternos)
    elseif evento == "GET_ITEM_INFO_RECEIVED" then
        if ventana and ventana:IsShown() and estado.modo == "chollos" and not FS.refrescoPendiente and C_Timer then
            FS.refrescoPendiente = true
            C_Timer.After(0.5, function() FS.refrescoPendiente = false; pcall(Refrescar) end)
        end
    elseif evento == "MAIL_INBOX_UPDATE" then
        pcall(LeerFacturas)
    elseif evento == "AUCTION_HOUSE_SHOW" then
        pcall(EngancharSubasta)
        pcall(CrearBotonesExternos)
        pcall(FS.ColocarBotonesSubasta)
        -- Auctionator y otros añaden sus pestañas al abrir la subasta: se vuelve a mirar un poco después.
        if C_Timer then
            C_Timer.After(0.3, function() pcall(FS.ColocarBotonesSubasta) end)
            C_Timer.After(1.5, function() pcall(FS.ColocarBotonesSubasta) end)
        end
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
        Imprimir("/subastas abre la ventana (qué fabricar, qué vender y tus cuentas). /subastas subir, /subastas vender, /subastas chollos y /subastas cuentas van directos a esas pestañas. /subastas cd muestra tus enfriamientos (Tela lunar, transmutaciones) y /subastas avisos activa o quita el aviso en el chat cuando quedan listos. El botón del minimapa enseña tus enfriamientos al pasar el ratón (/subastas minimapa lo oculta). Pasa el ratón por cualquier objeto para ver precios, tendencia, mejores horas y a cuánto venderlo. Abre tus profesiones una vez para que sepa qué recetas conoces.")
    elseif texto == "vender" then
        FS.Mostrar(nil, "vender")
    elseif texto == "subir" then
        FS.Mostrar(nil, "subir")
    elseif texto == "cuentas" then
        FS.Mostrar(nil, "cuentas")
    elseif texto == "chollos" then
        FS.Mostrar(nil, "chollos")
    elseif texto == "todas" then
        FS.Mostrar("todas", "fabricar")
    elseif texto == "cd" or texto == "enfriamientos" then
        ListarEnfriamientos()
    elseif texto == "minimapa" then
        local _, db = Personaje()
        db.sinMinimapa = not db.sinMinimapa or nil
        if FS.botonMinimapa then
            if db.sinMinimapa then FS.botonMinimapa:Hide() else FS.botonMinimapa:Show() end
        end
        Imprimir(db.sinMinimapa and "botón del minimapa oculto (/fsub minimapa para volver a verlo)." or "botón del minimapa visible.")
    elseif texto == "avisos" then
        local _, db = Personaje()
        db.sinAvisosCd = not db.sinAvisosCd or nil
        Imprimir(db.sinAvisosCd and "avisos de enfriamientos desactivados (/fsub avisos para volver a activarlos)."
            or "avisos de enfriamientos activados: te avisaré en el chat cuando la Tela lunar o una transmutación estén listas.")
    else
        FS.Mostrar()
    end
end
