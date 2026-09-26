-- Traduções conforme o idioma escolhido no KOReader (ver fineko_i18n.lua).
require("fineko_i18n").load(debug.getinfo(1, "S").source:match("@(.*/)"), "fineko")
local _ = require("gettext")
return {
    name = "destaquealeatorio",
    fullname = _("Destaque aleatório"),
    description = _([[Exibe um destaque aleatório dos seus livros ao abrir o KOReader ou ao retornar da suspensão.]]),
}
