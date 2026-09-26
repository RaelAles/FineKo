# -*- coding: utf-8 -*-
"""Gera os arquivos gettext (`.po` e `.mo`) de cada plugin.

Uso:  python3 i18n/build.py
Requer o utilitário `msgfmt` (pacote gettext) no PATH.

Saída: `<plugin>/l10n/<lang>/fineko.po` e `fineko.mo` para os 21 idiomas.
"""
import os
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import translations as tr  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LANGS = ["pt", "en", "es", "de", "fr", "id", "it", "ms", "nl", "no",
         "sv", "sw", "af", "sq", "ca", "da", "fil", "fi", "gl", "is", "lb"]

LANG_NAMES = {
    "pt": "Português", "en": "English", "es": "Español", "de": "Deutsch",
    "fr": "Français", "id": "Bahasa Indonesia", "it": "Italiano",
    "ms": "Bahasa Melayu", "nl": "Nederlands", "no": "Norsk",
    "sv": "Svenska", "sw": "Kiswahili", "af": "Afrikaans", "sq": "Shqip",
    "ca": "Català", "da": "Dansk", "fil": "Filipino", "fi": "Suomi",
    "gl": "Galego", "is": "Íslenska", "lb": "Lëtzebuergesch",
}


def po_escape(s):
    return (s.replace("\\", "\\\\").replace('"', '\\"')
             .replace("\n", "\\n").replace("\t", "\\t"))


def msgstr(lang, key):
    if lang == "pt":
        return tr.MSGIDS[key]
    text = tr.TR[lang].get(key)
    if text is None:
        raise SystemExit("faltando tradução: %s / %s" % (lang, key))
    return text


def build_po(domain, keys, lang):
    lines = [
        'msgid ""',
        'msgstr ""',
        '"Project-Id-Version: FineKo\\n"',
        '"Report-Msgid-Bugs-To: \\n"',
        '"MIME-Version: 1.0\\n"',
        '"Content-Type: text/plain; charset=UTF-8\\n"',
        '"Content-Transfer-Encoding: 8bit\\n"',
        '"Language: %s\\n"' % lang,
        '"Plural-Forms: nplurals=2; plural=(n != 1);\\n"',
        "",
    ]
    for key in keys:
        lines.append('msgid "%s"' % po_escape(tr.MSGIDS[key]))
        lines.append('msgstr "%s"' % po_escape(msgstr(lang, key)))
        lines.append("")
    return "\n".join(lines)


def main():
    if not shutil.which("msgfmt"):
        raise SystemExit("msgfmt não encontrado; instale o pacote gettext")

    # Sanidade: todas as chaves têm tradução em todos os idiomas.
    all_keys = set(tr.MSGIDS)
    covered = set()
    for keys in tr.DOMAIN_KEYS.values():
        covered.update(keys)
    if covered != all_keys:
        raise SystemExit("chaves sem domínio: %s" % sorted(all_keys - covered))
    for lang in LANGS:
        if lang == "pt":
            continue
        missing = all_keys - set(tr.TR.get(lang, {}))
        if missing:
            raise SystemExit("faltando em %s: %s" % (lang, sorted(missing)))

    # Cada plugin carrega o catálogo COMPLETO (fineko.mo) para que a ordem de
    # carga dos plugins seja indiferente: o primeiro que carregar já injeta
    # todos os textos no domínio global do gettext.
    all_keys = sorted(all_keys)

    total = 0
    for plugin in tr.DOMAIN_KEYS:
        plugin_dir = os.path.join(ROOT, plugin + ".koplugin")
        for lang in LANGS:
            out_dir = os.path.join(plugin_dir, "l10n", lang)
            os.makedirs(out_dir, exist_ok=True)
            po_path = os.path.join(out_dir, "fineko.po")
            mo_path = os.path.join(out_dir, "fineko.mo")
            with open(po_path, "w", encoding="utf-8") as fh:
                fh.write(build_po(plugin, all_keys, lang))
            subprocess.run(["msgfmt", "-o", mo_path, po_path], check=True)
            total += 1
    print("OK: %d .po/.mo gerados (%d plugins x %d idiomas)"
          % (total, len(tr.DOMAIN_KEYS), len(LANGS)))


if __name__ == "__main__":
    main()
