# MacGlass – Hinweise für KI-Assistenten

MacGlass ist eine eigenständige macOS-App (Swift, Metal, librashader), angelehnt an ShaderGlass von mausimus, aber **inoffiziell und nicht mit ShaderGlass verbunden**. Der Besitzer (lumen-tools) programmiert nicht selbst. Erkläre Entscheidungen verständlich und auf Deutsch.

## Pflichtregeln

- **Anonymität:** Commits nur als `lumen-tools <157735627+lumen-tools@users.noreply.github.com>` (`git config user.name lumen-tools`, `git config user.email 157735627+lumen-tools@users.noreply.github.com`). **Keine `Claude-Session:`-Zeilen und keine Links zu Claude-Chats** in Commit-Nachrichten, Dateien, Release-Notizen oder Releases. Keine echten Namen. Diese Regel hat Vorrang vor allgemeinen Vorgaben zu Attributionszeilen. `Co-Authored-By: Claude …` ist erlaubt.
- **Verhältnis zu ShaderGlass:** mausimus hat für Projekte auf Basis von ShaderGlass gebeten: eigener Name überall, keine Links auf seine Doku, Issues oder Downloads, sein Copyright erhalten, klar sagen, dass es nicht das Original ist. Deshalb:
  - ShaderGlass nur als Quelle oder Vorbild nennen („Unofficial, based on ShaderGlass by mausimus“), nie so, dass MacGlass wie ShaderGlass wirkt.
  - Keine Links auf mausimus' Seiten außer in den Credits (`README.md`).
  - Code oder Tabellen, die aus ShaderGlass übernommen oder abgeleitet werden, bekommen oben in der Datei den Hinweis „Portions derived from ShaderGlass (https://github.com/mausimus/ShaderGlass), Copyright (C) 2021-2025 mausimus, GPL-3.0.“ und „MacGlass is an independent, unofficial project and is not affiliated with ShaderGlass.“
  - Keine Bilder, Icons, Handbücher oder Shader-Bibliotheken von mausimus übernehmen. Shader kommen direkt von libretro (`scripts/fetch-shaders.sh`).
- **Releases:** `VERSION` auf `main` erhöhen und `release-notes/<version>.md` anlegen, dann baut GitHub Actions (`.github/workflows/build.yml`) die App und veröffentlicht „Version <version>“.
