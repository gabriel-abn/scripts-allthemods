--[[==========================================================================
  Fusion Reactor Ignition Controller  --  Mekanism 10 + CC:Tweaked 1.120
  ---------------------------------------------------------------------------
  Fluxo:
   1. Loop continuo.
   2. Validacoes de partida (uma vez); se falhar, TRAVA e mostra o erro no monitor:
        - 8 Laser Nodes respondem (discovery ping/pong)
        - Amplifier final + Redstone Relay presentes
        - Reator presente e formado
   3. Ativa todos os Nodes (carga).
   4. Nodes ficam ativos ate o Amplifier final encher.
   5. Cheio -> dispara SOMENTE se:
        - D-T Fuel suficiente no reator
        - Hohlraum com D-T (via hasHohlraum se existir; senao coberto por canIgnite)
        - canIgnite() == true
   6. Monitor sempre mostra o status atual do processo.

  Redes: CABO (reator, amplifier, relay, monitor) + WIRELESS (nos, rednet).
============================================================================]]

------------------------------------------------------------------ CONFIG
local PROTOCOL       = "lasernode"  -- canal rednet dos nos
local FIRE_SIDE      = "bottom"     -- face do Redstone Relay que toca o Amplifier
local EXPECTED_NODES = 8            -- quantos Laser Nodes devem responder
local DISCOVER_WIN   = 2            -- s de janela do discovery

local TARGET_FILL    = 0.99   -- carga (0-1) do amplifier p/ considerar "cheio"
local MIN_DT_FILL    = 0.10   -- fracao minima do tanque de D-T Fuel p/ disparar
local FIRE_PULSE     = 0.4    -- s do pulso de disparo
local POST_FIRE      = 2.0    -- s de espera apos disparo p/ o plasma atualizar
local POLL_INTERVAL  = 0.5    -- s entre amostragens ao carregar (< failsafe do no)
local IDLE_INTERVAL  = 2      -- s entre atualizacoes quando ocioso/aguardando
local INJECTION_RATE = 0      -- >0 forca setInjectionRate; 0 = nao mexer (voce controla)
local IGNITION_FALLBACK = 1e8 -- 100 MK, caso nao leia o alvo do reator

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

local function dtFill()
  local t = safe(reactor,"getDTFuel"); local amt = (type(t)=="table" and tonumber(t.amount)) or 0
  local cap = tonumber(safe(reactor,"getDTFuelCapacity")) or 0
  if cap <= 0 then return 0 end
  return amt / cap
end

local function burning()
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
    label(13, "canIgnite:",    tostring(safe(reactor,"canIgnite")))
    label(14, "Producao:",     sep(safe(reactor,"getProductionRate")).." FE/t")
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
local function chargeBroadcast(on) rednet.broadcast({ cmd = "charge", on = true }, PROTOCOL) end

local function fire()
  fireRelay.setOutput(FIRE_SIDE, true)
  sleep(FIRE_PULSE)
  fireRelay.setOutput(FIRE_SIDE, false)
end

-- condicoes do passo 5: retorna (ok, motivo_faltante)
local function fireConditions()
  if dtFill() < MIN_DT_FILL then return false, "Aguardando combustivel D-T" end
  if safe(reactor, "hasHohlraum") == false then return false, "Aguardando Hohlraum com D-T" end
  if safe(reactor, "canIgnite") ~= true then return false, "Aguardando condicoes (canIgnite)" end
  return true, nil
end

------------------------------------------------------------------ PARTIDA
chargeBroadcast(false)
if fireRelay then fireRelay.setOutput(FIRE_SIDE, false) end
if INJECTION_RATE > 0 then safe(reactor, "setInjectionRate", INJECTION_RATE) end
if mon then mon.setTextScale(1) end

local fault = validate()
if fault then
  showFault(fault)
  printError("[FALHA] "..fault)
  return   -- trava: monitor fica mostrando o problema
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
        chargeBroadcast(true)   -- heartbeat mantem os nos ligados
        drawState(string.format("Carregando amplificador (%.0f%%)", fill() * 100), colours.cyan)
        sleep(POLL_INTERVAL)
      end
      chargeBroadcast(false)    -- amplifier cheio: para de carregar, carga fica travada

      -- passo 5: so dispara quando todas as condicoes baterem
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
          if burning() then
            drawState("Ignicao bem-sucedida!", colours.lime)
          else
            drawState("Nao ignitou - repetindo ciclo", colours.orange)
          end
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
  showFault("Erro em execucao: "..tostring(err))
  printError(err)
else
  drawState("Encerrado.", colours.grey)
end
