local _ = require("gettext")
return {
    name = "estantemosaico",
    fullname = _("Estante mosaico"),
    description = _([[No modo mosaico, exibe sobre cada capa uma faixa central com o título do livro e um selo sutil com o estado de leitura (porcentagem ou concluído).

Funciona como camada sobre o plugin nativo "Cover browser", que precisa estar em modo mosaico.]]),
}
