--[[==========================================================================
  Teste de conexao de rede  --  Advanced Computer central (remoto)
  ---------------------------------------------------------------------------
  Exercita as tres redes de uma vez:
    1. WIRELESS (Ender Modem): ativa o no via rednet ("lasernode").
    2. RELAY (cabo): apos 3s, dispara o Amplifier final pelo redstone_relay.
    3. CABO: le o Fusion Reactor Logic Adapter e mostra no Monitor.

  So existe UM redstone_relay na rede (o de disparo), entao
  peripheral.find("redstone_relay") ja o identifica.
  Mantem heartbeat "on" pro no enquanto roda. Ctrl+T -> desliga tudo ao sair.
============================================================================]]

------------------------------------------------------------------ CONFIG
local PROTOCOL  = "lasernode"  -- mesmo canal do node_receiver.lua
local FIRE_SIDE = "bottom"     -- face do Redstone Relay que toca o Amplifier final
local NODE_WAIT = 3            -- s entre ativar o no e disparar o Amplifier
local REFRESH   = 1            -- s entre atualizacoes do monitor

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
  local s = tostring(math.floor(tonumber(n) or 0))
  local c
  repeat s, c = s:gsub("^(-?%d+)(%d%d%d)", "%1.%2") until c == 0
  return s
end

------------------------------------------------------------------ PERIFERICOS
local reactor   = peripheral.find("fusionReactorLogicAdapter")
local amplifier = peripheral.find("laserAmplifier")
local fireRelay = peripheral.find("redstone_relay")  -- unico relay na rede = o de disparo
local mon       = peripheral.find("monitor")
local out       = mon or term   -- Monitor e term compartilham a mesma API

local function tankAmt(getter)
  local t = safe(reactor, getter)
  if type(t) == "table" then return tonumber(t.amount) or 0 end
  return tonumber(t) or 0
end

-- abre o primeiro modem SEM FIO (Ender/Wireless) que encontrar
local modemSide
for _, side in ipairs(redstone.getSides()) do
  if peripheral.getType(side) == "modem" and peripheral.call(side, "isWireless") then
    rednet.open(side); modemSide = side; break
  end
end

------------------------------------------------------------------ DIAGNOSTICO INICIAL
term.clear(); term.setCursorPos(1, 1)
print("== Teste de conexao ==")
print(modemSide and ("Ender Modem: OK ("..modemSide..")") or "Ender Modem: NAO ENCONTRADO")
print(reactor   and "Reactor adapter: OK" or "Reactor adapter: NAO ENCONTRADO")
print(amplifier and "Amplifier final: OK" or "Amplifier final: NAO ENCONTRADO (so leitura)")
print(fireRelay and "Redstone Relay: OK"  or "Redstone Relay: NAO ENCONTRADO (sem disparo)")
print(mon       and "Monitor: OK"         or "Monitor: NAO ENCONTRADO (usando terminal)")
print("")

if not modemSide then
  print("Sem modem sem fio -> nao da pra testar o no. Abortando.")
  return
end

------------------------------------------------------------------ DESENHO DO MONITOR
if mon then mon.setTextScale(1) end

local function label(y, name, value, col)
  out.setCursorPos(1, y);  out.setTextColour(colours.lightGrey); out.write(name)
  out.setCursorPos(18, y); out.setTextColour(col or colours.white); out.write(tostring(value))
end

local function drawReactor(nodeOn, ampOn)
  out.setBackgroundColour(colours.black); out.clear()
  out.setCursorPos(1, 1); out.setTextColour(colours.cyan)
  out.write("TESTE DE CONEXAO")

  local formed = safe(reactor, "isFormed") == true
  label(3, "Reator formado:", formed and "SIM" or "NAO",
        formed and colours.lime or colours.red)

  if formed then
    label(4,  "Plasma:",         mk(safe(reactor, "getPlasmaTemperature")))
    label(5,  "Case:",           mk(safe(reactor, "getCaseTemperature")))
    label(6,  "Ignicao (alvo):", mk(safe(reactor, "getIgnitionTemperature", false)))
    label(8,  "Deuterio:", sep(tankAmt("getDeuterium")).." / "..sep(safe(reactor,"getDeuteriumCapacity")).." mB")
    label(9,  "Tritio:",   sep(tankAmt("getTritium"))  .." / "..sep(safe(reactor,"getTritiumCapacity"))  .." mB")
    label(10, "DT Fuel:",  sep(tankAmt("getDTFuel"))   .." / "..sep(safe(reactor,"getDTFuelCapacity"))   .." mB")
    label(11, "Injecao:",  tostring(safe(reactor, "getInjectionRate") or "-"))
    label(12, "Producao:", sep(safe(reactor, "getProductionRate")).." FE/t")
  else
    label(4, "(reator nao formado - sem leituras)", "", colours.grey)
  end

  local fillPct = (tonumber(safe(amplifier, "getEnergyFilledPercentage")) or 0) * 100
  label(14, "Amplifier carga:", amplifier and string.format("%.1f %%", fillPct) or "n/d")

  label(16, "No (rednet):",  nodeOn and "ATIVADO" or "desligado",
        nodeOn and colours.lime or colours.grey)
  label(17, "Relay disparo:", ampOn and "ON" or "off",
        ampOn and colours.lime or colours.grey)
  out.setTextColour(colours.white)
end

------------------------------------------------------------------ SEQUENCIA DO TESTE
local function runTest()
  -- 1) ativa o no (com heartbeat durante a espera de 3s)
  write("Ativando o no via rednet... ")
  for _ = 1, NODE_WAIT do rednet.broadcast(true, PROTOCOL); sleep(1) end
  print("ok (verifique se a fonte do no ligou)")

  -- 2) dispara o Amplifier final pelo relay
  if fireRelay then
    write("Disparando o Amplifier final (relay, face "..FIRE_SIDE..")... ")
    fireRelay.setOutput(FIRE_SIDE, true)
    print("ok")
  else
    print("[pulando disparo: Redstone Relay ausente]")
  end

  -- 3) leitura continua do reator no monitor (mantendo o no vivo)
  print("Mostrando dados do reator. Ctrl+T para parar.")
  while true do
    rednet.broadcast(true, PROTOCOL)   -- heartbeat: mantem o no ligado
    local ampOn = fireRelay ~= nil and fireRelay.getOutput(FIRE_SIDE) or false
    drawReactor(true, ampOn)
    sleep(REFRESH)
  end
end

------------------------------------------------------------------ EXECUCAO + LIMPEZA
local ok, err = pcall(runTest)

-- ao sair (inclusive Ctrl+T): desliga tudo
rednet.broadcast(false, PROTOCOL)
if fireRelay then fireRelay.setOutput(FIRE_SIDE, false) end
if mon then mon.setBackgroundColour(colours.black); mon.clear() end
print("\nTeste encerrado. No e disparo desligados.")
if not ok and err ~= "Terminated" then printError(err) end
