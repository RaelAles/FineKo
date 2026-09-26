-- Traduções conforme o idioma escolhido no KOReader (ver fineko_i18n.lua).
require("fineko_i18n").load(debug.getinfo(1, "S").source:match("@(.*/)"), "fineko")
local _ = require("gettext")
return {
    name = "atualizarmetadados",
    fullname = _("Atualizar metadados"),
    description = _("Agrega metadados de livros por ISBN de várias fontes gratuitas (Google Books, Open Library, Inventaire, Amazon), com edição campo a campo e escolha da capa de maior qualidade."),
}
