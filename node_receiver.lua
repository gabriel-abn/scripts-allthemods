--[[==========================================================================
  Laser Node Receiver  --  CC:Tweaked
  ---------------------------------------------------------------------------
  Roda em CADA computador de Laser Node. Escuta o "canal" (protocol) do
  controlador via rednet e reflete o estado desejado no redstone que aciona
  a fonte de energia daquele Node.

  Desenho (proposital):
    - O controlador transmite o ESTADO DESEJADO (on/off), não eventos de borda.
    - A aplicação é idempotente: recebeu "on" -> liga; recebeu "off" -> desliga.
    - Failsafe: se ficar TIMEOUT segundos sem ouvir o controlador (crash,
      fora de alcance, chunk descarregado), assume OFF. Você nunca quer um
      array de lasers preso em ON sem supervisão.
============================================================================]]

local MODEM_SIDE = "top"       -- lado do computador com o modem (Ender/Wireless)
local OUT_SIDE   = "back"     -- lado que aciona a fonte de energia do Node
local PROTOCOL   = "lasernode"  -- "SSID" da rede: TODOS os Nodes usam o mesmo
local TIMEOUT    = 3            -- s sem mensagem -> estado seguro (OFF)

rednet.open(MODEM_SIDE)
redstone.setOutput(OUT_SIDE, false)
print("Node receiver ativo. Canal: "..PROTOCOL.."  | modem: "..MODEM_SIDE)

while true do
  local id, msg = rednet.receive(PROTOCOL, TIMEOUT)
  if id == nil then
    -- perdeu contato com o controlador -> desliga por seguranca
    redstone.setOutput(OUT_SIDE, false)
  else
    -- aplica o estado desejado (msg e um booleano vindo do controlador)
    redstone.setOutput(OUT_SIDE, msg == true)
  end
end
