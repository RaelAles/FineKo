-- Traduções conforme o idioma escolhido no KOReader (ver fineko_i18n.lua).
require("fineko_i18n").load(debug.getinfo(1, "S").source:match("@(.*/)"), "fineko")
local _ = require("gettext")
return {
    fullname = _("Estante mosaico"),
    description = _([[No modo mosaico, exibe sobre cada capa uma faixa central com o título
do livro e um selo sutil com o estado de leitura (porcentagem ou concluído).

Funciona como camada sobre o plugin nativo "Cover browser", que precisa estar
em modo mosaico.]]),
}
