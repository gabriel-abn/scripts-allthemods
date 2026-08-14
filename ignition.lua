--[[==========================================================================
  Fusion Reactor Ignition Controller  --  HIBRIDO (relay + rednet)
    Mekanism 10 + CC:Tweaked 1.120
  ---------------------------------------------------------------------------
  Computador REMOTO. Duas redes:
    CABO   : fusionReactorLogicAdapter (le temp/fuel)
             laserAmplifier final       (le carga %)
             redstone_relay             (DISPARA o Amplifier final)
             monitor (opcional)
    WIRELESS (Ender Modem, rednet "lasernode"):
             ativa a fonte de energia de cada Laser Node
             (cada no roda node_receiver.lua, com failsafe de 3s)

  So existe UM redstone_relay na rede (o de disparo), entao
  peripheral.find("redstone_relay") ja o identifica - sem nome fixo.
  Pare com Ctrl+T -> ao sair, desliga carga (broadcast off) e disparo.
============================================================================]]

------------------------------------------------------------------ CONFIG
local PROTOCOL   = "lasernode"  -- mesmo canal do node_receiver.lua
local FIRE_SIDE  = "bottom"     -- face do relay que toca o Amplifier final

local TARGET_FILL    = 0.99   -- carga do amplifier (0-1) p/ considerar "cheio"
local CHARGE_TIMEOUT = 30     -- s max. esperando encher antes de disparar assim mesmo
local FIRE_PULSE     = 0.4    -- s de duracao do pulso de disparo
local SETTLE_TIME    = 0.5    -- s de pausa apos parar de carregar, antes de disparar
local POST_FIRE      = 2.0    -- s de espera apos disparo p/ o plasma atualizar
local POLL_INTERVAL  = 0.5    -- s entre amostragens (< failsafe de 3s do no)
local IDLE_INTERVAL  = 5      -- s entre checagens quando ocioso / ignitado
local INJECTION_RATE = 2      -- mB/t de D-T (0 = nao mexer). Multiplos de 2.
local IGNITION_FALLBACK = 1e8 -- 100 MK, caso nao leia o alvo do reator

------------------------------------------------------------------ PERIFERICOS
local reactor   = peripheral.find("fusionReactorLogicAdapter")
local amplifier = peripheral.find("laserAmplifier")
local fireRelay = peripheral.find("redstone_relay")   -- unico relay na rede

-- abre o primeiro modem SEM FIO (Ender/Wireless) que encontrar
local modemSide
for _, side in ipairs(redstone.getSides()) do
  if peripheral.getType(side) == "modem" and peripheral.call(side, "isWireless") then
    rednet.open(side); modemSide = side; break
  end
end

local function fatal(m) printError("[ERRO] "..m); error(m, 0) end
if not reactor   then fatal("Reactor Logic Adapter nao encontrado na rede.") end
if not amplifier then fatal("Laser Amplifier final nao encontrado na rede.") end
if not fireRelay then fatal("Redstone Relay de disparo nao encontrado na rede.") end
if not modemSide then fatal("Ender Modem (sem fio) nao encontrado - carga dos nos indisponivel.") end

------------------------------------------------------------------ HELPERS
local function safe(obj, method, ...)
  if not obj then return nil end
  local fn = obj[method]
  if type(fn) ~= "function" then return nil end
  local ok, res = pcall(fn, ...)
  if ok then return res end
  return nil
end

local function ignitionTarget()
  return tonumber(safe(reactor, "getIgnitionTemperature", false)) or IGNITION_FALLBACK
end
local function plasmaTemp() return tonumber(safe(reactor, "getPlasmaTemperature")) or 0 end
local function fill()       return tonumber(safe(amplifier, "getEnergyFilledPercentage")) or 0 end
local function isFormed()   return safe(reactor, "isFormed") == true end
local function isIgnited()  return plasmaTemp() >= ignitionTarget() end

local function hasFuel()
  local ci = safe(reactor, "canIgnite")
  if ci ~= nil then return ci end
  local d  = safe(reactor, "getDeuterium"); d  = (d  and d.amount)  or 0
  local t  = safe(reactor, "getTritium");   t  = (t  and t.amount)  or 0
  local dt = safe(reactor, "getDTFuel");    dt = (dt and dt.amount) or 0
  return (dt > 0) or (d > 0 and t > 0)
end

-- carga: broadcast do estado desejado pros nos (idempotente + heartbeat)
local function chargeBroadcast(on) rednet.broadcast(on, PROTOCOL) end

-- disparo: pulsa o relay -> Amplifier final dispara
local function fire()
  fireRelay.setOutput(FIRE_SIDE, true)
  sleep(FIRE_PULSE)
  fireRelay.setOutput(FIRE_SIDE, false)
end

------------------------------------------------------------------ SEQUENCIA DE IGNICAO
local function chargeAndFire()
  print("-> Carregando os nos via rednet...")

  local t0 = os.clock()
  while true do
    chargeBroadcast(true)              -- heartbeat: mantem os nos ligados (<3s)
    local f = fill()
    local elapsed = os.clock() - t0
    print(string.format("   amplifier: %5.1f%%   (%.0fs)", f * 100, elapsed))
    if f >= TARGET_FILL then print("   amplifier cheio."); break end
    if elapsed >= CHARGE_TIMEOUT then print("   timeout - disparando assim mesmo."); break end
    sleep(POLL_INTERVAL)
  end

  chargeBroadcast(false)               -- desliga os nos
  sleep(SETTLE_TIME)
  print("-> Disparando o Amplifier final no reator...")
  fire()
  sleep(POST_FIRE)
end

------------------------------------------------------------------ SETUP + LOOP
chargeBroadcast(false)
fireRelay.setOutput(FIRE_SIDE, false)
if INJECTION_RATE > 0 then safe(reactor, "setInjectionRate", INJECTION_RATE) end

print("Controlador hibrido iniciado (modem: "..modemSide..").")
print(string.format("Alvo de ignicao: %.3e K", ignitionTarget()))

local ok, err = pcall(function()
  while true do
    if not isFormed() then
      print("[AVISO] Reator nao formado. Aguardando...")
      sleep(IDLE_INTERVAL)

    elseif isIgnited() then
      print(string.format("IGNITADO. Plasma: %.3e K | Producao: %s FE/t",
            plasmaTemp(), tostring(safe(reactor, "getProductionRate"))))
      sleep(IDLE_INTERVAL)

    elseif not hasFuel() then
      print("[AVISO] Sem combustivel D-T suficiente. Aguardando...")
      sleep(IDLE_INTERVAL)

    else
      print(string.format("Plasma abaixo do alvo (%.3e K). Ciclo de ignicao.", plasmaTemp()))
      chargeAndFire()
      print(isIgnited() and "[OK] Ignicao bem-sucedida!" or "[..] Ainda nao ignitou. Repetindo.")
    end
  end
end)

-- limpeza ao sair (inclusive Ctrl+T)
chargeBroadcast(false)
fireRelay.setOutput(FIRE_SIDE, false)
print("\nEncerrado. Carga (rednet) e disparo (relay) desligados.")
if not ok and err ~= "Terminated" then printError(err) end
