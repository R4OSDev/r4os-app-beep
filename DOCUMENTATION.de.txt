BEEP.R4X
========

BEEP.R4X ist ein einfaches Terminal-Werkzeug fuer den R4OS-Audiopfad.

Projektstruktur seit 0.51.18:
- `build.zig` ruft seit 0.58.29 nur noch den generischen SDK-R4MF-Treiber.
- `build.zig.zon` bindet `r4os_sdk` als Paket.
- `module.R4MF` v2 beschreibt Sprache, Quelle, Klasse, Ziel, Scope und Imports.

Build:

    DevTools\Scripts\Build.bat -app BEEP

Ergebnis:

    Code\zig-out\BEEP.R4X

Contract:
- fachlicher Einstieg: `r4_app_main`; das SDK exportiert `R4XStart`
- App-Klasse: `console`
- Zielpfad im Image: `C:\R4OS\SOFTWARE\TERMINAL\BEEP.R4X`
