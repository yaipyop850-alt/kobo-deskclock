# kobo-deskclock — working rules

KOReader plugin (desk clock & Google Calendar) for the owner's Kobo Aura HD (1080×1440, 265 dpi, Mark 4, 1 GHz single core).
Reply to the owner in Korean, polite speech (존댓말).

## Release checklist (every change that ships)

1. Bump `VERSION` in `deskclock.koplugin/dc_store.lua`.
2. Update `release.txt` (`version=`, `files=` must list every plugin file, `notes=` one line in Korean).
3. Commit and push to `main`. Devices fetch from
   `https://raw.githubusercontent.com/yaipyop850-alt/kobo-deskclock/main/` (CDN cache up to ~5 min).
4. **Update the development log (개발 일지) every time** — the owner asked for this as a standing rule:
   - Doc: https://claude.ai/artifact/R9V8o7E7jDXJmogaj8sMLn  (Claude Docs, title "책상 시계·달력 플러그인 개발 기록")
   - Add a row to "버전별 기록" (버전 · 날짜 · 추가·수정 내용 · 계기), chronological order (oldest first).
   - Add anything considered but not adopted / dropped to "고려했으나 채택하지 않거나 폐기한 내용" with the reason.
   - Move items out of "보류 중인 개선 후보" when they are done or rejected; update "알려진 제약과 배운 점" if relevant.
5. Also bump the version line in the install guide doc: https://claude.ai/artifact/1WnV3DUGs6DAK3dfRzAKdv
   ("플러그인 버전: x.y" in step 5) and add/adjust usage text when behaviour changes.

## KOReader pitfalls already hit (do not repeat)

- `VerticalGroup`/`HorizontalGroup`/`OverlapGroup` cache their layout on the first `getSize()`.
  Never call `getSize()` on a group that will still receive children (v2.2 crash).
- `FrameContainer` `width`/`height` only enlarge the painted background; layout uses content + padding.
  For fixed-size boxes use `WidgetContainer{dimen=...}`, `CenterContainer`/`LeftContainer` with `dimen`,
  or a `LineWidget` of the wanted size (v2.7 month-view bug).
- Test with the simulator in `tools/sim` (see `tools/README.md`) before shipping; render every screen
  (clock / calendar / month / memo × landscape / portrait, sleep, date pick, popups, sync) on several dates,
  and run `tools/tests/*` when touching sending, Tasks sync or network code.
- The simulator cannot see: e-ink refresh regions (use the widget's real `getSize()` for `setDirty` areas,
  v3.6.1), Wi-Fi/network states (`NetworkMgr:runWhenOnline` drops callbacks, v3.1), real font widths, speed.
- Apps Script (`apps-script/Code.gs`) is not updated by the device updater: the owner pastes it by hand.
  Never put the owner's SECRET in the repo; give a filled copy only in chat/attachment when asked.

## Code layout

- `dc_widget.lua` screens · `dc_ui.lua` shared drawing helpers (text, wrapText, checkbox, todoRows, colours)
- `dc_todopopup.lua` to-do popup · `dc_wake.lua` timed wake-ups (KOReader `Device.wakeup_mgr`, Kobo only)
- `dc_store.lua` settings/calendars/sync · `dc_memo.lua` memos, outbox, Google Tasks · `dc_ics.lua` iCal parser
- `dc_update.lua` self-update · `main.lua` menu, dispatcher, diagnostics
- New plugin files must be added to `files=` in `release.txt`, or devices will not get them.

## Privacy

- Never commit real calendar URLs (`deskclock_urls.txt`, `deskclock_write.txt` are git-ignored), the Apps Script
  URL/secret, account e-mail addresses, or real student names.
  Sample data uses fictional names (학생A).
