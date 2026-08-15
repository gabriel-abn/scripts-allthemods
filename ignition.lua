--[[==========================================================================
  Fusion Reactor Ignition Controller  --  Mekanism 10 + CC:Tweaked 1.120
  ---------------------------------------------------------------------------
  Condicoes de disparo (passo 5) mapeadas aos metodos REAIS da build:
    5.1 Hohlraum: getHohlraum() -> count>0, name "mekanismgenerators:hohlraum",
                  e components contendo "fusion_fuel"
    5.2 D-T Fuel: getDTFuelFilledPercentage() >= MIN_DT_FILL
    5.3 ignicao : nao ha canIgnite; garantido por burning()==false (loop) + amplifier cheio
============================================================================]]

------------------------------------------------------------------ CONFIG
local PROTOCOL       = "lasernode"
local FIRE_SIDE      = "bottom"
local EXPECTED_NODES = 8
local DISCOVER_WIN   = 2

local TARGET_FILL    = 0.99   -- carga (0-1) do amplifier p/ "cheio"
local MIN_DT_FILL    = 0.10   -- fracao minima do tanque interno de D-T Fuel
local FIRE_PULSE     = 0.4
local POST_FIRE      = 2.0
local POLL_INTERVAL  = 0.5
local IDLE_INTERVAL  = 2
local INJECTION_RATE = 0      -- >0 forca setInjectionRate; 0 = nao mexer
local IGNITION_FALLBACK = 1e8

------------------------------------------------------------------ PERIFERICOS
local reactor   = peripheral.find("fusionReactorLogicAdapter")
local amplifier = peripheral.find("laserAmplifier")
local fireRelay = peripheral.find("redstone_relay")
local mon       = peripheral.find("monitor")
local out       = mon or term

local modemSide
for _, side in ipairs(redstone.getSides()) do
  if peripheral.getType(side) == "modem" and peripheral.call(side, "isWireless") then
    rednet.open(side); modemSide = side; break
  end
end

local NODES_ONLINE = 0

------------------------------------------------------------------ HELPERS
local function safe(obj, method, ...)
  if not obj then return nil end
  local fn = obj[method]
  if type(fn) ~= "function" then return nil end
  local ok, res = pcall(fn, ...)
  if ok then return res end
  return nil
end

local function mk(k) return string.format("%.2f MK", (tonumber(k) or 0) / 1e6) end
local function sep(n)
  local s = tostring(math.floor(tonumber(n) or 0)); local c
  repeat s, c = s:gsub("^(-?%d+)(%d%d%d)", "%1.%2") until c == 0
  return s
end

local function ignitionTarget() return tonumber(safe(reactor,"getIgnitionTemperature", false)) or IGNITION_FALLBACK end
local function plasmaTemp()     return tonumber(safe(reactor,"getPlasmaTemperature")) or 0 end
local function fill()           return tonumber(safe(amplifier,"getEnergyFilledPercentage")) or 0 end
local function isFormed()       return safe(reactor,"isFormed") == true end

-- D-T Fuel: usa getDTFuelFilledPercentage (0-1); fallback amount/capacity
local function dtFill()
  local p = tonumber(safe(reactor, "getDTFuelFilledPercentage"))
  if p then return p end
  local t = safe(reactor,"getDTFuel"); local amt = (type(t)=="table" and tonumber(t.amount)) or 0
  local cap = tonumber(safe(reactor,"getDTFuelCapacity")) or 0
  return cap > 0 and amt/cap or 0
end

-- Hohlraum: retorna present(bool|nil), withDT(bool)
local function hohlraum()
  local h = safe(reactor, "getHohlraum")
  if type(h) ~= "table" then return nil, false end   -- metodo ausente -> desconhecido
  local present = (tonumber(h.count) or 0) > 0 and h.name == "mekanismgenerators:hohlraum"
  local withDT  = present and type(h.components) == "string"
                  and h.components:find("fusion_fuel") ~= nil
  return present, withDT
end

local function burning()
  local ig = safe(reactor, "isIgnited")
  if ig ~= nil then return ig == true end
  -- fallback caso a build nao tenha isIgnited
  if (tonumber(safe(reactor,"getProductionRate")) or 0) > 0 then return true end
  return plasmaTemp() >= ignitionTarget()
end

------------------------------------------------------------------ MONITOR
local function label(y, name, value, col)
  out.setCursorPos(1, y);  out.setTextColour(colours.lightGrey); out.write(name)
  out.setCursorPos(16, y); out.setTextColour(col or colours.white); out.write(tostring(value))
end

local function drawState(status, col)
  out.setBackgroundColour(colours.black); out.clear()
  out.setCursorPos(1, 1); out.setTextColour(colours.cyan); out.write("FUSION REACTOR - IGNICAO")

  out.setCursorPos(1, 3); out.setTextColour(colours.lightGrey); out.write("STATUS:")
  out.setCursorPos(9, 3); out.setTextColour(col or colours.white); out.write(status)

  label(5, "Nos online:", NODES_ONLINE.."/"..EXPECTED_NODES,
        NODES_ONLINE >= EXPECTED_NODES and colours.lime or colours.orange)
  label(6, "Amplifier:",  string.format("%.1f %%", fill() * 100))

  local formed = isFormed()
  label(8, "Reator:", formed and "formado" or "NAO formado", formed and colours.lime or colours.red)
  if formed then
    label(9,  "Plasma:",       mk(plasmaTemp()))
    label(10, "Ignicao alvo:", mk(ignitionTarget()))
    label(11, "D-T Fuel:",     string.format("%.0f %%", dtFill() * 100))
    label(12, "Injecao:",      tostring(safe(reactor,"getInjectionRate") or "-"))
    local present, withDT = hohlraum()
    local hstr = present == nil and "n/d"
              or (present and (withDT and "com D-T" or "sem D-T") or "ausente")
    label(13, "Hohlraum:", hstr, (present and withDT) and colours.lime or colours.orange)
    label(14, "Producao:", sep(safe(reactor,"getProductionRate")).." FE/t")
  end
  out.setTextColour(colours.white)
end

local function showFault(msg)
  out.setBackgroundColour(colours.black); out.clear()
  out.setCursorPos(1, 1); out.setTextColour(colours.red);  out.write("FALHA NA VALIDACAO")
  out.setCursorPos(1, 3); out.setTextColour(colours.white); out.write(msg)
  out.setCursorPos(1, 5); out.setTextColour(colours.grey)
  out.write("Programa travado. Corrija e reinicie (Ctrl+R).")
  out.setTextColour(colours.white)
end

------------------------------------------------------------------ DISCOVERY + VALIDACAO
local function discoverNodes()
  if not modemSide then return 0 end
  rednet.broadcast({ cmd = "ping" }, PROTOCOL)
  local seen, n = {}, 0
  local timer = os.startTimer(DISCOVER_WIN)
  while true do
    local ev, a, b, c = os.pullEvent()
    if ev == "rednet_message" and c == PROTOCOL and type(b) == "table"
       and b.cmd == "pong" and not seen[a] then
      seen[a] = true; n = n + 1
    elseif ev == "timer" and a == timer then
      break
    end
  end
  return n
end

local function validate()
  if not modemSide then return "Ender Modem ausente (rede dos nos)" end
  if not reactor   then return "Reactor Logic Adapter ausente" end
  if not isFormed()then return "Reator nao formado" end
  if not amplifier then return "Laser Amplifier final ausente" end
  if not fireRelay then return "Redstone Relay de disparo ausente" end
  drawState("Procurando Laser Nodes...", colours.cyan)
  NODES_ONLINE = discoverNodes()
  if NODES_ONLINE < EXPECTED_NODES then
    return string.format("Nos: so %d de %d responderam", NODES_ONLINE, EXPECTED_NODES)
  end
  return nil
end

------------------------------------------------------------------ ACOES
local function chargeBroadcast(on) rednet.broadcast({ cmd = "charge", on = on }, PROTOCOL) end

local function fire()
  fireRelay.setOutput(FIRE_SIDE, true)
  sleep(FIRE_PULSE)
  fireRelay.setOutput(FIRE_SIDE, false)
end

-- condicoes do passo 5 (metodos reais da build)
local function fireConditions()
  if dtFill() < MIN_DT_FILL then return false, "Aguardando combustivel D-T" end
  local present, withDT = hohlraum()
  if present == false then return false, "Aguardando Hohlraum" end
  if present == true and not withDT then return false, "Hohlraum sem D-T Fuel" end
  return true, nil
end

------------------------------------------------------------------ PARTIDA
chargeBroadcast(false)
if fireRelay then fireRelay.setOutput(FIRE_SIDE, false) end
if INJECTION_RATE > 0 then safe(reactor, "setInjectionRate", INJECTION_RATE) end
if mon then mon.setTextScale(1) end

local fault = validate()
if fault then
  showFault(fault); printError("[FALHA] "..fault)
  return
end

------------------------------------------------------------------ LOOP PRINCIPAL
local ok, err = pcall(function()
  while true do
    if burning() then
      chargeBroadcast(false)
      drawState("Reator ignitado (estavel)", colours.lime)
      sleep(IDLE_INTERVAL)

    else
      -- passo 3-4: carrega ate o Amplifier final encher
      while fill() < TARGET_FILL and not burning() do
        chargeBroadcast(true)
        drawState(string.format("Carregando amplificador (%.0f%%)", fill() * 100), colours.cyan)
        sleep(POLL_INTERVAL)
      end
      chargeBroadcast(false)

      -- passo 5: dispara so quando todas as condicoes baterem
      if not burning() then
        local ready, reason = fireConditions()
        while not ready and not burning() do
          drawState(reason, colours.orange)
          sleep(IDLE_INTERVAL)
          ready, reason = fireConditions()
        end
        if ready and not burning() then
          drawState("Disparando laser...", colours.yellow)
          fire()
          sleep(POST_FIRE)
          drawState(burning() and "Ignicao bem-sucedida!" or "Nao ignitou - repetindo ciclo",
                    burning() and colours.lime or colours.orange)
          sleep(1)
        end
      end
    end
  end
end)

------------------------------------------------------------------ LIMPEZA
chargeBroadcast(false)
if fireRelay then fireRelay.setOutput(FIRE_SIDE, false) end
if not ok and err ~= "Terminated" then
  showFault("Erro em execucao: "..tostring(err)); printError(err)
else
  drawState("Encerrado.", colours.grey)
end
