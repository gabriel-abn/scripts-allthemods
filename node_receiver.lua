--[[==========================================================================
  Laser Node Receiver  --  CC:Tweaked  (com discovery ping/pong)
  ---------------------------------------------------------------------------
  Roda em CADA computador de Laser Node (salvar como startup).
  Protocolo de mensagens (tabelas) no canal PROTOCOL:
    recebe {cmd="charge", on=<bool>}  -> liga/desliga a fonte de energia
    recebe {cmd="ping"}               -> responde {cmd="pong", id=<meu id>}
  Failsafe: TIMEOUT s sem NENHUMA mensagem -> desliga (estado seguro).
============================================================================]]

local MODEM_SIDE = "top"       -- lado com o Ender/Wireless Modem
local OUT_SIDE   = "back"     -- lado que aciona a fonte de energia do Node
local PROTOCOL   = "lasernode"  -- "SSID" da rede: TODOS os Nodes usam o mesmo
local TIMEOUT    = 3            -- s sem mensagem -> estado seguro (OFF)

rednet.open(MODEM_SIDE)
redstone.setOutput(OUT_SIDE, false)
print("Node receiver ativo. Canal: "..PROTOCOL.."  | id: "..os.getComputerID())

while true do
  local id, msg = rednet.receive(PROTOCOL, TIMEOUT)
  if id == nil then
    redstone.setOutput(OUT_SIDE, false)                 -- failsafe: sem contato
  elseif type(msg) == "table" then
    if msg.cmd == "ping" then
      rednet.send(id, { cmd = "pong", id = os.getComputerID() }, PROTOCOL)
    elseif msg.cmd == "charge" then
      redstone.setOutput(OUT_SIDE, msg.on == true)
    end
  end
end
