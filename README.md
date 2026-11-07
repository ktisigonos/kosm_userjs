# kosm_userjs

Firefox's `user.js` for kosm: the `userjs` adapter reads and writes the
`user_pref("name", value);` lines Firefox, Zen and other Firefox-based browsers read from a
profile at startup, and `// kosm:begin` blocks in them (D96). Apps for those browsers use it;
`kosm_zen` writes Zen's prefs through it.

`.js` is JavaScript, so the adapter claims no extension: pass `.lang = "userjs"`.

- **Paths:** a pref is one key named by its whole name, so its path is quoted:
  `prefs.set("\"zen.theme.accent-color\"", ...)` (D32).
- **Values:** Firefox prefs hold only a bool, a 32-bit integer or a string. Colors are written as
  strings (`#rrggbb` by default, D70), joined values as one string. A float, or an integer
  outside 32 bits, is an error, never turned into a string silently: pass `"1.25"` yourself.
  Booleans are always `true`/`false`, whatever `format.boolean` says, since Firefox reads nothing
  else.
- **Reading:** `//`, `/* */` and `#` comments are skipped. Anything but `user_pref` (`pref`,
  `sticky_pref`, stray text) is an error naming the line.
