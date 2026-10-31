--[[
  RELOJ PRO — script para OBS Studio (Windows / macOS / Linux)

  Instalación:
    OBS → Herramientas → Scripts → "+" → elige este archivo (reloj_pro.lua)
    Luego pulsa "Añadir reloj a la escena actual".

  Crea y mantiene estas fuentes de texto:
    <nombre>                 → la hora
    <nombre> (fecha)         → la fecha (debajo de la hora)
    <nombre> (sombra)        → copia detrás de la hora, desplazada, que hace de sombra
    <nombre> (fecha sombra)  → lo mismo para la fecha
  Muévelas / escálalas moviendo SOLO la fuente de la hora: lo demás la sigue.
]]

obs = obslua

------------------------------------------------------------------
-- Estado
------------------------------------------------------------------
local S = {}          -- ajustes actuales
local cur = nil       -- obs_data de los ajustes del script
local last = {}       -- caché del último texto enviado a cada fuente
local IS_WINDOWS = package.config:sub(1, 1) == "\\"
local TEXT_ID = IS_WINDOWS and "text_gdiplus" or "text_ft2_source"

local function log(msg)
  obs.script_log(obs.LOG_WARNING, "[Reloj Pro] " .. tostring(msg))
end

-- Crea una fuente de texto probando los ids que existen según la versión de OBS.
-- OJO: quien la llame debe añadirla a una escena ANTES de liberarla, si no OBS la destruye.
local function create_text_source(nm, st)
  local ids = IS_WINDOWS and { "text_gdiplus_v3", "text_gdiplus_v2", "text_gdiplus" }
                          or { "text_ft2_source_v2", "text_ft2_source" }
  for _, id in ipairs(ids) do
    local src = obs.obs_source_create(id, nm, st, nil)
    if src ~= nil then
      log("Fuente '" .. nm .. "' creada con el tipo " .. id)
      return src
    end
  end
  log("NO se pudo crear la fuente '" .. nm .. "' (ningún tipo de texto disponible)")
  return nil
end

local function abgr(hex)
  local r = tonumber(hex:sub(2, 3), 16)
  local g = tonumber(hex:sub(4, 5), 16)
  local b = tonumber(hex:sub(6, 7), 16)
  return r + g * 256 + b * 65536 + 4278190080
end

local function hasbit(v, b) return math.floor(v / b) % 2 == 1 end

local function names()
  local n = S.name or "Reloj Pro"
  return { time = n, time_sh = n .. " (sombra)", date = n .. " (fecha)", date_sh = n .. " (fecha sombra)" }
end

------------------------------------------------------------------
-- Formato de hora y fecha
------------------------------------------------------------------
local LANG = {
  es = {
    days    = { "domingo", "lunes", "martes", "miércoles", "jueves", "viernes", "sábado" },
    dshort  = { "dom", "lun", "mar", "mié", "jue", "vie", "sáb" },
    months  = { "enero", "febrero", "marzo", "abril", "mayo", "junio", "julio", "agosto", "septiembre", "octubre", "noviembre", "diciembre" },
    mshort  = { "ene", "feb", "mar", "abr", "may", "jun", "jul", "ago", "sep", "oct", "nov", "dic" },
    long    = function(L, t) return string.format("%s %d de %s de %d", L.days[t.wday], t.day, L.months[t.month], t.year) end,
    medium  = function(L, t) return string.format("%s %d %s %d", L.dshort[t.wday], t.day, L.mshort[t.month], t.year) end,
    numeric = function(L, t) return string.format("%02d/%02d/%d", t.day, t.month, t.year) end,
    compact = function(L, t) return string.format("%s %d de %s", L.days[t.wday], t.day, L.months[t.month]) end,
  },
  en = {
    days    = { "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" },
    dshort  = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" },
    months  = { "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" },
    mshort  = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" },
    long    = function(L, t) return string.format("%s, %s %d, %d", L.days[t.wday], L.months[t.month], t.day, t.year) end,
    medium  = function(L, t) return string.format("%s %s %d, %d", L.dshort[t.wday], L.mshort[t.month], t.day, t.year) end,
    numeric = function(L, t) return string.format("%02d/%02d/%d", t.month, t.day, t.year) end,
    compact = function(L, t) return string.format("%s, %s %d", L.days[t.wday], L.months[t.month], t.day) end,
  },
}

local UP = { ["á"] = "Á", ["é"] = "É", ["í"] = "Í", ["ó"] = "Ó", ["ú"] = "Ú", ["ñ"] = "Ñ", ["ü"] = "Ü" }
local function upper(s)
  s = s:upper()
  for k, v in pairs(UP) do s = s:gsub(k, v) end
  return s
end

local function now()
  local t = os.time()
  if S.tz_mode == "offset" then
    return os.date("!*t", t + math.floor((S.utc_offset or 0) * 3600))
  end
  return os.date("*t", t)       -- hora local de tu PC (la zona que tengas en Windows)
end

local function fmt_time(t)
  local h, suffix = t.hour, ""
  if S.h12 then
    suffix = (h >= 12) and "PM" or "AM"
    h = h % 12
    if h == 0 then h = 12 end
  end
  local hs = S.pad and string.format("%02d", h) or tostring(h)
  local sep = (S.blink and t.sec % 2 == 1) and " " or ":"
  local s = hs .. sep .. string.format("%02d", t.min)
  if S.seconds then s = s .. sep .. string.format("%02d", t.sec) end
  if S.h12 and S.ampm then s = s .. " " .. suffix end
  return s
end

local function fmt_date(t)
  local L = LANG[S.lang] or LANG.es
  local f = L[S.date_fmt] or L.long
  local s = f(L, t)
  s = s:sub(1, 1):upper() .. s:sub(2)
  if S.date_upper then s = upper(s) end
  return s
end

------------------------------------------------------------------
-- Estilos de las fuentes de texto
------------------------------------------------------------------
local function font_obj(scale)
  local f = obs.obs_data_create()
  obs.obs_data_set_string(f, "face", S.font_face)
  obs.obs_data_set_string(f, "style", S.font_style)
  obs.obs_data_set_int(f, "size", math.max(6, math.floor(S.font_size * scale + 0.5)))
  obs.obs_data_set_int(f, "flags", S.font_flags)
  return f
end

local function build(role, shadow)
  local d = obs.obs_data_create()
  local scale = (role == "date") and (S.date_scale / 100) or 1
  local f = font_obj(scale)
  obs.obs_data_set_obj(d, "font", f)
  obs.obs_data_release(f)

  local c1, c2, grad, opacity
  if shadow then
    c1, c2, grad, opacity = S.sh_color, S.sh_color, false, S.sh_opacity
  elseif role == "date" then
    c1, c2, grad, opacity = S.date_color, S.date_color, false, S.date_opacity
  else
    c1, c2, grad, opacity = S.color1, S.color2, S.gradient, S.opacity
  end
  if not grad then c2 = c1 end

  -- GDI+ (Windows) y FreeType2 (otros): se rellenan las dos familias de claves
  obs.obs_data_set_int(d, "color", c1)
  obs.obs_data_set_int(d, "color1", c1)
  obs.obs_data_set_int(d, "color2", c2)
  obs.obs_data_set_bool(d, "gradient", grad)
  obs.obs_data_set_int(d, "gradient_color", c2)
  obs.obs_data_set_double(d, "gradient_dir", S.angle)
  obs.obs_data_set_int(d, "gradient_opacity", 100)
  obs.obs_data_set_int(d, "opacity", opacity)

  obs.obs_data_set_bool(d, "outline", S.outline)
  obs.obs_data_set_bool(d, "outline_enabled", S.outline)
  obs.obs_data_set_int(d, "outline_size", S.outline_size)
  obs.obs_data_set_int(d, "outline_color", shadow and S.sh_color or S.outline_color)
  obs.obs_data_set_int(d, "outline_opacity", shadow and S.sh_opacity or 100)

  obs.obs_data_set_string(d, "align", "center")
  obs.obs_data_set_string(d, "valign", "center")
  obs.obs_data_set_bool(d, "extents", false)
  obs.obs_data_set_bool(d, "antialiasing", true)
  return d
end

local function push_styles()
  local n = names()
  local defs = {
    { n.time, "time", false }, { n.time_sh, "time", true },
    { n.date, "date", false }, { n.date_sh, "date", true },
  }
  for _, d in ipairs(defs) do
    local src = obs.obs_get_source_by_name(d[1])
    if src ~= nil then
      local st = build(d[2], d[3])
      obs.obs_source_update(src, st)
      obs.obs_data_release(st)
      obs.obs_source_release(src)
    end
  end
  last = {}
end

local function set_text(name, text)
  if last[name] == text then return end
  local src = obs.obs_get_source_by_name(name)
  if src ~= nil then
    local d = obs.obs_data_create()
    obs.obs_data_set_string(d, "text", text)
    obs.obs_source_update(src, d)
    obs.obs_data_release(d)
    obs.obs_source_release(src)
    last[name] = text
  end
end

------------------------------------------------------------------
-- Escenas: la sombra y la fecha siguen a la hora
------------------------------------------------------------------
local function place(item, px, py, sx, sy, rot, align, vis)
  local p, s = obs.vec2(), obs.vec2()
  obs.obs_sceneitem_get_pos(item, p)
  obs.obs_sceneitem_get_scale(item, s)
  if math.abs(p.x - px) > 0.01 or math.abs(p.y - py) > 0.01 then
    p.x = px; p.y = py
    obs.obs_sceneitem_set_pos(item, p)
  end
  if math.abs(s.x - sx) > 0.0001 or math.abs(s.y - sy) > 0.0001 then
    s.x = sx; s.y = sy
    obs.obs_sceneitem_set_scale(item, s)
  end
  if math.abs(obs.obs_sceneitem_get_rot(item) - rot) > 0.01 then
    obs.obs_sceneitem_set_rot(item, rot)
  end
  if obs.obs_sceneitem_get_alignment(item) ~= align then
    obs.obs_sceneitem_set_alignment(item, align)
  end
  if obs.obs_sceneitem_visible(item) ~= vis then
    obs.obs_sceneitem_set_visible(item, vis)
  end
end

-- Busca el item en la escena; si no está y `want` es true, crea la fuente (si no existe)
-- y la añade justo debajo de `ref`
local function ensure_item(scene, name, ref, want, role, shadow)
  local it = obs.obs_scene_find_source(scene, name)
  if it == nil and want then
    local src = obs.obs_get_source_by_name(name)
    if src == nil then
      local st = build(role, shadow)
      src = create_text_source(name, st)
      obs.obs_data_release(st)
      last[name] = nil
    end
    if src ~= nil then
      it = obs.obs_scene_add(scene, src)
      obs.obs_source_release(src)   -- ahora la escena ya tiene su propia referencia
      if it ~= nil and ref ~= nil then
        obs.obs_sceneitem_set_order_position(it, obs.obs_sceneitem_get_order_position(ref))
      end
    end
  end
  return it
end

local function transform_of(item)
  local p, s = obs.vec2(), obs.vec2()
  obs.obs_sceneitem_get_pos(item, p)
  obs.obs_sceneitem_get_scale(item, s)
  return p.x, p.y, s.x, s.y, obs.obs_sceneitem_get_rot(item), obs.obs_sceneitem_get_alignment(item)
end

local function sync_scene(scene)
  local n = names()
  local main = obs.obs_scene_find_source(scene, n.time)
  if main == nil then return end

  local px, py, sx, sy, rot, align = transform_of(main)
  local vis = obs.obs_sceneitem_visible(main)

  -- sombra de la hora
  local sh = ensure_item(scene, n.time_sh, main, S.shadow, "time", true)
  if sh ~= nil then
    place(sh, px + S.sh_x, py + S.sh_y, sx, sy, rot, align, vis and S.shadow)
  end

  -- fecha
  local date = ensure_item(scene, n.date, main, S.show_date, "date", false)
  if date ~= nil then
    local dvis = vis and S.show_date
    if S.anchor and S.show_date then
      local msrc = obs.obs_sceneitem_get_source(main)
      local w = obs.obs_source_get_width(msrc) * sx
      local h = obs.obs_source_get_height(msrc) * sy
      local ax = hasbit(align, 1) and 0 or (hasbit(align, 2) and 1 or 0.5)
      local ay = hasbit(align, 4) and 0 or (hasbit(align, 8) and 1 or 0.5)
      local cx = px - w * ax + w / 2
      local bottom = py - h * ay + h
      place(date, cx, bottom + S.date_gap * sy, sx, sy, rot, 4, dvis)
    elseif obs.obs_sceneitem_visible(date) ~= dvis then
      obs.obs_sceneitem_set_visible(date, dvis)
    end

    local dsh = ensure_item(scene, n.date_sh, date, S.show_date and S.shadow, "date", true)
    if dsh ~= nil then
      local dx, dy, dsx, dsy, drot, dalign = transform_of(date)
      place(dsh, dx + S.sh_x, dy + S.sh_y, dsx, dsy, drot, dalign, dvis and S.shadow)
    end
  end
end

local function sync_all()
  local scenes = obs.obs_frontend_get_scenes()
  if scenes == nil then return end
  for _, s in ipairs(scenes) do
    local scene = obs.obs_scene_from_source(s)
    if scene ~= nil then sync_scene(scene) end
  end
  obs.source_list_release(scenes)
end

------------------------------------------------------------------
-- Tic del reloj
------------------------------------------------------------------
local function tick_impl()
  if S.name == nil then return end
  local n = names()
  local t = now()
  local ts = fmt_time(t)
  set_text(n.time, ts)
  set_text(n.time_sh, ts)
  if S.show_date then
    local ds = fmt_date(t)
    set_text(n.date, ds)
    set_text(n.date_sh, ds)
  end
  sync_all()
end

local last_err = nil
local function tick()
  local ok, err = pcall(tick_impl)
  if not ok and err ~= last_err then
    last_err = err
    log("Error en el reloj: " .. tostring(err))
  end
end

------------------------------------------------------------------
-- Botón: crear fuentes y añadirlas a la escena actual
------------------------------------------------------------------
local function add_clock_impl(props, prop)
  local n = names()
  local curscene = obs.obs_frontend_get_current_scene()
  if curscene == nil then
    log("No hay escena actual")
    return true
  end
  local scene = obs.obs_scene_from_source(curscene)
  if scene ~= nil and obs.obs_scene_find_source(scene, n.time) == nil then
    -- reutiliza la fuente si ya existe en otra escena; si no, la crea
    local src = obs.obs_get_source_by_name(n.time)
    if src == nil then
      local st = build("time", false)
      src = create_text_source(n.time, st)
      obs.obs_data_release(st)
      last[n.time] = nil
    end
    if src ~= nil then
      local item = obs.obs_scene_add(scene, src)
      obs.obs_source_release(src)   -- la escena ya la retiene
      if item ~= nil then
        obs.obs_sceneitem_set_alignment(item, 0)   -- centrado
        local w, h = 1920, 1080
        local okv, ovi = pcall(function()
          local o = obs.obs_video_info()
          obs.obs_get_video_info(o)
          return o
        end)
        if okv and ovi ~= nil and ovi.base_width > 0 then w, h = ovi.base_width, ovi.base_height end
        local p = obs.vec2()
        p.x = w / 2
        p.y = h / 2
        obs.obs_sceneitem_set_pos(item, p)
        log("Reloj añadido a la escena actual")
      end
    end
  end
  obs.obs_source_release(curscene)
  tick()   -- pone el texto y crea/coloca fecha y sombras
  return true
end

local function add_clock(props, prop)
  local ok, err = pcall(add_clock_impl, props, prop)
  if not ok then log("Error al añadir el reloj: " .. tostring(err)) end
  return true
end

------------------------------------------------------------------
-- Preajustes
------------------------------------------------------------------
local PRESETS = {
  ["Neón cian"]      = { font = { "Segoe UI", "Bold", 1 }, gradient = true, color1 = "#00e5ff", color2 = "#7c4dff", angle = 0,
                         outline = false, shadow = true, sh_color = "#000000", sh_opacity = 60, sh_x = 0, sh_y = 6, date_color = "#ffffff" },
  ["Oro lujo"]       = { font = { "Georgia", "Bold", 1 }, gradient = true, color1 = "#fff1a8", color2 = "#c98a00", angle = 90,
                         outline = false, shadow = true, sh_color = "#000000", sh_opacity = 65, sh_x = 0, sh_y = 8, date_color = "#f3d77a" },
  ["Atardecer"]      = { font = { "Trebuchet MS", "Bold", 1 }, gradient = true, color1 = "#ff9a3c", color2 = "#ff3d81", angle = 0,
                         outline = false, shadow = true, sh_color = "#000000", sh_opacity = 55, sh_x = 0, sh_y = 6, date_color = "#ffffff" },
  ["Blanco minimal"] = { font = { "Segoe UI", "Regular", 0 }, gradient = false, color1 = "#ffffff", color2 = "#ffffff",
                         outline = false, shadow = true, sh_color = "#000000", sh_opacity = 45, sh_x = 0, sh_y = 4, date_color = "#ffffff" },
  ["LED verde"]      = { font = { "Consolas", "Bold", 1 }, gradient = false, color1 = "#39ff14", color2 = "#39ff14",
                         outline = false, shadow = false, sh_color = "#000000", sh_opacity = 60, sh_x = 0, sh_y = 4, date_color = "#39ff14" },
  ["Arcade retro"]   = { font = { "Impact", "Regular", 0 }, gradient = true, color1 = "#fff200", color2 = "#ff2d2d", angle = 90,
                         outline = true, outline_size = 6, outline_color = "#1a0033",
                         shadow = true, sh_color = "#000000", sh_opacity = 100, sh_x = 6, sh_y = 6, date_color = "#fff200" },
}
local PRESET_ORDER = { "Neón cian", "Oro lujo", "Atardecer", "Blanco minimal", "LED verde", "Arcade retro" }
local COLORKEY = { color1 = true, color2 = true, outline_color = true, sh_color = true, date_color = true }

local function apply_preset(props, prop)
  local name = obs.obs_data_get_string(cur, "preset")
  local P = PRESETS[name]
  if P == nil then return false end
  for k, v in pairs(P) do
    if k == "font" then
      local f = obs.obs_data_create()
      obs.obs_data_set_string(f, "face", v[1])
      obs.obs_data_set_string(f, "style", v[2])
      obs.obs_data_set_int(f, "size", S.font_size or 120)
      obs.obs_data_set_int(f, "flags", v[3])
      obs.obs_data_set_obj(cur, "font", f)
      obs.obs_data_release(f)
    elseif COLORKEY[k] then
      obs.obs_data_set_int(cur, k, abgr(v))
    elseif type(v) == "boolean" then
      obs.obs_data_set_bool(cur, k, v)
    else
      obs.obs_data_set_int(cur, k, v)
    end
  end
  script_update(cur)
  return true
end

------------------------------------------------------------------
-- Interfaz del script
------------------------------------------------------------------
function script_description()
  return "<b>Reloj Pro</b><br>Reloj con la hora de tu PC, fecha, degradados, contorno y sombra. " ..
         "Pulsa «Añadir reloj a la escena actual» y mueve solo la fuente de la hora: la fecha y las sombras la siguen."
end

function script_properties()
  local p = obs.obs_properties_create()

  obs.obs_properties_add_button(p, "add", "➕  Añadir reloj a la escena actual", add_clock)
  obs.obs_properties_add_text(p, "name", "Nombre de la fuente", obs.OBS_TEXT_DEFAULT)

  local pre = obs.obs_properties_add_list(p, "preset", "Preajuste", obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
  for _, nm in ipairs(PRESET_ORDER) do obs.obs_property_list_add_string(pre, nm, nm) end
  obs.obs_properties_add_button(p, "apply_preset", "Aplicar preajuste", apply_preset)

  -- Hora
  local tz = obs.obs_properties_add_list(p, "tz_mode", "Zona horaria", obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
  obs.obs_property_list_add_string(tz, "Hora de mi PC (automática)", "local")
  obs.obs_property_list_add_string(tz, "Otra: desfase UTC manual", "offset")
  obs.obs_properties_add_float_slider(p, "utc_offset", "Desfase UTC (horas, solo si eliges «Otra»)", -12, 14, 0.5)
  obs.obs_properties_add_bool(p, "h12", "Formato 12 horas")
  obs.obs_properties_add_bool(p, "ampm", "Mostrar AM/PM")
  obs.obs_properties_add_bool(p, "pad", "Cero a la izquierda en la hora")
  obs.obs_properties_add_bool(p, "seconds", "Mostrar segundos")
  obs.obs_properties_add_bool(p, "blink", "Parpadeo de «:» (mejor con fuente monoespaciada)")

  -- Fecha
  obs.obs_properties_add_bool(p, "show_date", "Mostrar fecha")
  local fm = obs.obs_properties_add_list(p, "date_fmt", "Formato de fecha", obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
  obs.obs_property_list_add_string(fm, "Larga (viernes 30 de octubre de 2026)", "long")
  obs.obs_property_list_add_string(fm, "Media (vie 30 oct 2026)", "medium")
  obs.obs_property_list_add_string(fm, "Numérica (30/10/2026)", "numeric")
  obs.obs_property_list_add_string(fm, "Sin año (viernes 30 de octubre)", "compact")
  local lg = obs.obs_properties_add_list(p, "lang", "Idioma de la fecha", obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
  obs.obs_property_list_add_string(lg, "Español", "es")
  obs.obs_property_list_add_string(lg, "English", "en")
  obs.obs_properties_add_bool(p, "date_upper", "Fecha en MAYÚSCULAS")
  obs.obs_properties_add_int_slider(p, "date_scale", "Tamaño de la fecha (% de la hora)", 10, 100, 1)
  obs.obs_properties_add_color(p, "date_color", "Color de la fecha")
  obs.obs_properties_add_int_slider(p, "date_opacity", "Opacidad de la fecha", 0, 100, 1)
  obs.obs_properties_add_bool(p, "anchor", "Mantener la fecha pegada bajo la hora")
  obs.obs_properties_add_int_slider(p, "date_gap", "Separación hora–fecha (px)", -50, 100, 1)

  -- Tipografía y relleno
  obs.obs_properties_add_font(p, "font", "Fuente (tipo, estilo y tamaño)")
  obs.obs_properties_add_bool(p, "gradient", "Usar degradado")
  obs.obs_properties_add_color(p, "color1", "Color 1")
  obs.obs_properties_add_color(p, "color2", "Color 2 (degradado)")
  obs.obs_properties_add_int_slider(p, "angle", "Ángulo del degradado (0 = horizontal, 90 = vertical)", 0, 360, 5)
  obs.obs_properties_add_int_slider(p, "opacity", "Opacidad del texto", 0, 100, 1)

  -- Contorno
  obs.obs_properties_add_bool(p, "outline", "Contorno")
  obs.obs_properties_add_int_slider(p, "outline_size", "Grosor del contorno", 1, 30, 1)
  obs.obs_properties_add_color(p, "outline_color", "Color del contorno")

  -- Sombra
  obs.obs_properties_add_bool(p, "shadow", "Sombra")
  obs.obs_properties_add_color(p, "sh_color", "Color de la sombra")
  obs.obs_properties_add_int_slider(p, "sh_opacity", "Opacidad de la sombra", 0, 100, 1)
  obs.obs_properties_add_int_slider(p, "sh_x", "Desplazamiento X (px)", -60, 60, 1)
  obs.obs_properties_add_int_slider(p, "sh_y", "Desplazamiento Y (px)", -60, 60, 1)

  return p
end

function script_defaults(settings)
  obs.obs_data_set_default_string(settings, "name", "Reloj Pro")
  obs.obs_data_set_default_string(settings, "preset", "Neón cian")
  obs.obs_data_set_default_string(settings, "tz_mode", "local")
  obs.obs_data_set_default_double(settings, "utc_offset", 0)
  obs.obs_data_set_default_bool(settings, "h12", false)
  obs.obs_data_set_default_bool(settings, "ampm", true)
  obs.obs_data_set_default_bool(settings, "pad", true)
  obs.obs_data_set_default_bool(settings, "seconds", true)
  obs.obs_data_set_default_bool(settings, "blink", false)

  obs.obs_data_set_default_bool(settings, "show_date", true)
  obs.obs_data_set_default_string(settings, "date_fmt", "long")
  obs.obs_data_set_default_string(settings, "lang", "es")
  obs.obs_data_set_default_bool(settings, "date_upper", false)
  obs.obs_data_set_default_int(settings, "date_scale", 28)
  obs.obs_data_set_default_int(settings, "date_color", abgr("#ffffff"))
  obs.obs_data_set_default_int(settings, "date_opacity", 90)
  obs.obs_data_set_default_bool(settings, "anchor", true)
  obs.obs_data_set_default_int(settings, "date_gap", 4)

  local f = obs.obs_data_create()
  obs.obs_data_set_string(f, "face", "Segoe UI")
  obs.obs_data_set_string(f, "style", "Bold")
  obs.obs_data_set_int(f, "size", 120)
  obs.obs_data_set_int(f, "flags", 1)
  obs.obs_data_set_default_obj(settings, "font", f)
  obs.obs_data_release(f)

  obs.obs_data_set_default_bool(settings, "gradient", true)
  obs.obs_data_set_default_int(settings, "color1", abgr("#00e5ff"))
  obs.obs_data_set_default_int(settings, "color2", abgr("#7c4dff"))
  obs.obs_data_set_default_int(settings, "angle", 0)
  obs.obs_data_set_default_int(settings, "opacity", 100)

  obs.obs_data_set_default_bool(settings, "outline", false)
  obs.obs_data_set_default_int(settings, "outline_size", 4)
  obs.obs_data_set_default_int(settings, "outline_color", abgr("#000000"))

  obs.obs_data_set_default_bool(settings, "shadow", true)
  obs.obs_data_set_default_int(settings, "sh_color", abgr("#000000"))
  obs.obs_data_set_default_int(settings, "sh_opacity", 60)
  obs.obs_data_set_default_int(settings, "sh_x", 0)
  obs.obs_data_set_default_int(settings, "sh_y", 6)
end

function script_update(settings)
  cur = settings
  S.name = obs.obs_data_get_string(settings, "name")
  if S.name == "" then S.name = "Reloj Pro" end
  S.tz_mode = obs.obs_data_get_string(settings, "tz_mode")
  S.utc_offset = obs.obs_data_get_double(settings, "utc_offset")
  S.h12 = obs.obs_data_get_bool(settings, "h12")
  S.ampm = obs.obs_data_get_bool(settings, "ampm")
  S.pad = obs.obs_data_get_bool(settings, "pad")
  S.seconds = obs.obs_data_get_bool(settings, "seconds")
  S.blink = obs.obs_data_get_bool(settings, "blink")

  S.show_date = obs.obs_data_get_bool(settings, "show_date")
  S.date_fmt = obs.obs_data_get_string(settings, "date_fmt")
  S.lang = obs.obs_data_get_string(settings, "lang")
  S.date_upper = obs.obs_data_get_bool(settings, "date_upper")
  S.date_scale = obs.obs_data_get_int(settings, "date_scale")
  S.date_color = obs.obs_data_get_int(settings, "date_color")
  S.date_opacity = obs.obs_data_get_int(settings, "date_opacity")
  S.anchor = obs.obs_data_get_bool(settings, "anchor")
  S.date_gap = obs.obs_data_get_int(settings, "date_gap")

  local f = obs.obs_data_get_obj(settings, "font")
  S.font_face, S.font_style, S.font_size, S.font_flags = "Segoe UI", "Bold", 120, 1
  if f ~= nil then
    local face = obs.obs_data_get_string(f, "face")
    if face ~= "" then S.font_face = face end
    local style = obs.obs_data_get_string(f, "style")
    if style ~= "" then S.font_style = style end
    local size = obs.obs_data_get_int(f, "size")
    if size > 0 then S.font_size = size end
    S.font_flags = obs.obs_data_get_int(f, "flags")
    obs.obs_data_release(f)
  end

  S.gradient = obs.obs_data_get_bool(settings, "gradient")
  S.color1 = obs.obs_data_get_int(settings, "color1")
  S.color2 = obs.obs_data_get_int(settings, "color2")
  S.angle = obs.obs_data_get_int(settings, "angle")
  S.opacity = obs.obs_data_get_int(settings, "opacity")

  S.outline = obs.obs_data_get_bool(settings, "outline")
  S.outline_size = obs.obs_data_get_int(settings, "outline_size")
  S.outline_color = obs.obs_data_get_int(settings, "outline_color")

  S.shadow = obs.obs_data_get_bool(settings, "shadow")
  S.sh_color = obs.obs_data_get_int(settings, "sh_color")
  S.sh_opacity = obs.obs_data_get_int(settings, "sh_opacity")
  S.sh_x = obs.obs_data_get_int(settings, "sh_x")
  S.sh_y = obs.obs_data_get_int(settings, "sh_y")

  push_styles()
  tick()
end

function script_load(settings)
  cur = settings
  obs.timer_add(tick, 250)
end

function script_unload()
  obs.timer_remove(tick)
end
