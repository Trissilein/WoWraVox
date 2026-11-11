# Aura-Tracker: Fähigkeitsvertrag

Stand: 2026-11-11. Dieser Vertrag trennt Quellcodebelege von noch offenen Live-Tests.

## Durch Quellcode und API-Dokumentation belegt

- Der Add-on-Kern verfolgt konfigurierte Spieler-Auren. Für lesbare Auren speichert er `expirationTime` und `auraInstanceID`; Ablaufprüfungen laufen über vorhandene Timer in `WoWraVox.lua`.
- Der Cooldown-Manager-Adapter bildet öffentliche Basis-, Override- und verknüpfte Spell-IDs ab. Er beobachtet Aura-Anwendung, Aura-Entfernung und aktive Zustandswechsel in `WoWraVoxTooltip.lua`.
- Das aktuelle CDM-Signal an den Kern liefert nur aktiv/inaktiv. Es liefert weder Ablaufzeit noch Countdownobjekt.
- Forever und Retail dokumentieren `C_UnitAuras.GetAuraDuration(unit, auraInstanceID)` sowie `DurationObject:HasSecretValues()`. `Cooldown:SetCooldownFromDurationObject()` ist ebenfalls in beiden API-Dokumentationen vorhanden. Das belegt den nativen Darstellungsweg, nicht die Laufzeit-Lesbarkeit eines konkreten Siegel-Auras.
- Blizzards `PandemicTime` ist kein allgemeiner Vorwarnzeitpunkt. Die Forever-Implementierung setzt ihn nur für unterstützte Auren mit positivem Refresh-Carryover.
- Der vorhandene Spellbook-Scanner kann gelernte Zauber und Namen finden. Er belegt keine Siegel-Cast-ID-zu-Aura-ID-Zuordnung.

## Implementierungsvertrag

| Fähigkeit | Verhalten |
|---|---|
| Lesbare direkte Aura mit öffentlicher Ablaufzeit | Eigenen Countdown und konfigurierbare Vorwarnung erlauben. Vorwarnung je Aura-Instanz höchstens einmal; Refresh ersetzt Timer. |
| Geheime Aura oder nicht lesbare Zeit | Zustand bleibt `unknown`, solange keine positive CDM-Aktivmeldung vorliegt. Keine Abwesenheitsannahme. Zwischenmarker der Zeitleiste dürfen mit geschätzter Dauer laufen (Regel-Override `durationOverride`, sonst die zuletzt lesbare Dauer aus `WoWraVoxProfilesDB.auraDurations`); sie gelten als „geschätzt“. 0 % und 100 % bleiben an echte Ereignisse gebunden (Entscheidung Ingo, 2026-11-11). |
| CDM-Aktivmeldung ohne lesbare Zeit | Anwesenheit anzeigen; Ablauf und freie Vorwarnung als nicht verfügbar markieren. Blizzard-CDM bleibt bedienbar. |
| CDM-Inaktivmeldung | Nur als Ende verwenden, wenn bestehende Aura-/Secrecy-Regeln das Ende bestätigen. Unbekanntheit nicht als Entfernung behandeln. |
| Blizzard-`PandemicTime` | Erst anbinden, wenn der Client für die betreffende Aura reproduzierbar ein passendes Signal auslöst. Nie als frei wählbare Sekundenschwelle darstellen. |
| Siegel-Familie | Gelernten Zauber zunächst als Kandidat führen. Cast-ID und Aura-ID getrennt halten; ungeklärte Zuordnung nicht als aktiven Tracker-Eintrag oder Warnquelle ausgeben. |
| Quelle wechselt zwischen Aura-API und CDM | Bestehende Instanz fortführen. Quellewechsel, Einblenden und Vorschau erzeugen keine Aura-Ausgabe. |

Retail und Forever teilen diesen Fail-Closed-Vertrag. Die konkrete Daueranzeige und Warnfähigkeit gilt je Client und Aura erst nach Live-Nachweis.

## Noch nötige Live-Proben

Für jede Probe Client-Build, Spell-ID, beobachtete Aura-ID, `auraInstanceID`, Ablaufzeit-Lesbarkeit, `GetAuraDuration`-Ergebnis, Geheimhaltungsstatus, CDM-Zuordnung und tatsächlich beobachtetes Signal festhalten.

1. **Forever:** Siegel außerhalb des Kampfes wirken; Kampf betreten; Siegel im Kampf wirken und erneuern; Siegel wechseln; durch Richturteil verbrauchen; natürlich auslaufen lassen; danach `/reload`.
2. **Retail:** Eine lesbare Spieler-Aura und eine Aura mit geschützten Zeitwerten anwenden; Anwendung, Refresh und Ende prüfen.
3. **CDM:** Aura-Symbol aktivieren und entfernen; prüfen, ob Laufzeitobjekt oder Vorablaufsignal tatsächlich öffentlich verfügbar sind.
4. **Ausgabe:** Vorwarnung in TTS, Sound und Bildschirmtext je Instanz genau einmal prüfen; Refresh und Entfernung müssen alte Warnungen abbrechen.

Bis diese Proben bestanden sind, werden keine CDM-Vorwarnung und keine allgemeine Siegel-Vorwarnung zugesichert.

## Primärquellen

- [Forever UnitAura API](https://github.com/Gethe/wow-ui-source/blob/forever/Interface/AddOns/Blizzard_APIDocumentationGenerated/UnitAuraDocumentation.lua)
- [Forever LuaDurationObject API](https://github.com/Gethe/wow-ui-source/blob/forever/Interface/AddOns/Blizzard_APIDocumentationGenerated/LuaDurationObjectAPIDocumentation.lua)
- [Forever Blizzard Cooldown Viewer](https://github.com/Gethe/wow-ui-source/blob/forever/Interface/AddOns/Blizzard_CooldownViewer/CooldownViewer.lua)

- [Retail UnitAura API](https://github.com/Gethe/wow-ui-source/blob/live/Interface/AddOns/Blizzard_APIDocumentationGenerated/UnitAuraDocumentation.lua)
- [Forever Cooldown API](https://github.com/Gethe/wow-ui-source/blob/forever/Interface/AddOns/Blizzard_APIDocumentationGenerated/FrameAPICooldownDocumentation.lua)
- [Retail Cooldown API](https://github.com/Gethe/wow-ui-source/blob/live/Interface/AddOns/Blizzard_APIDocumentationGenerated/FrameAPICooldownDocumentation.lua)
