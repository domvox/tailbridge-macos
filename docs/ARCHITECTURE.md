# Architektura TailBridge v1

## Składniki

| Składnik | Uprawnienia | Rola |
|---|---|---|
| `TailBridge.app` (AppKit) | użytkownik | Stan, Włącz/Wyłącz/Sprawdź, diagnostyka, plik env w kontenerze Tailscale. Start aplikacji niczego nie zmienia. |
| `com.tailbridge.helper` (Swift, jedna binarka) | root, `/Library/PrivilegedHelperTools`, `root:wheel 755` | Stałe polecenia: `enable`, `disable`, `watch`, `status`, `install-daemon`, `uninstall`. Brak ogólnego wykonywania poleceń. |
| LaunchDaemon `com.tailbridge.helper` | root | `helper watch` co 5 s. **Tylko usuwa** nieaktualne elementy; nigdy sam niczego nie włącza. |

`src/Core` jest wspólny i testowany na fixture'ach (`tests/main.swift`) przez wstrzyknięty `SystemOps` (atrapa PF i interfejsów, katalog tymczasowy zamiast `/etc`).

## Uprawnienia

- Instalacja: jeden dialog `osascript ... with administrator privileges`. Skrypt kopiuje binarkę z pakietu do pliku tymczasowego należącego do roota, sprawdza SHA-256 (wartość pokazana w dialogu), ustawia `root:wheel 755`, przenosi atomowo i dopiero wtedy uruchamia **chronioną kopię**.
- Każde `enable`/`disable` to osobny dialog administratora. Uruchamiana jest wyłącznie chroniona binarka, a argumenty są walidowane w GUI i ponownie w pomocniku.
- Pomocnik sprawdza własną ścieżkę oraz właściciela i uprawnienia każdego katalogu nadrzędnego. Uruchamia tylko `/sbin/pfctl`, `/usr/bin/dscacheutil`, `/usr/bin/killall` i `/bin/launchctl`, ze stałym `PATH` i `cwd=/`. Nie czyta plików użytkownika, nie wywołuje CLI Mullvad ani Tailscale.

## Stan rzeczywisty

- Zamiar: `/Library/Application Support/TailBridge/enabled.json` (tożsamość: utun, indeks, IPv4, IPv6, domena).
- Obserwacja: `status.json` (644, zawiera domenę tailnetu i adresy Tailscale) zapisywany przez monitor przy każdym cyklu. Zawiera dokładność anchora odczytaną z `pfctl -a com.apple/tailbridge -sr`, kolejność anchorów, stan resolvera i elementów prototypu.
- GUI pokazuje wiek obserwacji. Brak świeżego `status.json` oznacza brak aktualnego potwierdzenia; monitor może być zatrzymany lub zablokowany. Stan nigdy nie jest wnioskowany z samej obecności pliku.

## Reguły PF (anchor `com.apple/tailbridge`)

```
pass out quick on <utun> inet  from <ts4> to 100.64.0.0/10        flags any no state
pass in  quick on <utun> inet  from 100.64.0.0/10 to <ts4>        flags any no state
pass out quick on <utun> inet6 from <ts6> to fd7a:115c:a1e0::/48  flags any no state
pass in  quick on <utun> inet6 from fd7a:115c:a1e0::/48 to <ts6>  flags any no state
```

Ładowanie: `pfctl -a com.apple/tailbridge -f <plik>`. Brak `-f /etc/pf.conf` i brak `-e`/`-d`.
Weryfikacja: dokładne porównanie zbioru linii z `-sr` z oczekiwaną postacią wydruku, bez `sed`. Pojawienie się `flags S/SA` oznacza niezgodność i wycofanie.
Oczekiwana postać wydruku (`... no state`, bez `flags`) została potwierdzona na żywo na macOS 27.2. Jeśli się różni, `enable` podejmuje wycofanie i raportuje błędy.

## Cykl życia i sprzątanie, z ograniczeniami

`enable`: walidacja → tożsamość interfejsu z `getifaddrs` → PF włączony, `com.apple/*` przed `mullvad` → klasyfikacja anchora i resolvera prototypu → **najpierw zapis zamiaru** (monitor staje się agentem wycofania) → załadowanie i dokładna weryfikacja anchora → resolver → usunięcie rozpoznanego anchora prototypu i kopia jego stanu → odświeżenie DNS. Dokładny zakres wycofania i kroków kończących się tylko ostrzeżeniem opisuje [SECURITY.md](../SECURITY.md). Nie jest to gwarancja braku wycieków ani pełnego fail-closed.

`teardown`: flush własnego anchora i weryfikacja pustki. Resolver jest usuwany tylko przy dokładnie rozpoznanej treści; zmieniony zostaje nietknięty i zgłoszony. Zamiar jest usuwany wyłącznie po udanym czyszczeniu PF. Każdy krok raportuje błąd, a wynik `ok` jest możliwy tylko wtedy, gdy wszystkie kroki się udały.

Monitor (co 5 s) wywołuje `teardown`, gdy interfejs zniknie, nie jest UP, zmieni indeks lub adresy, gdy adres pojawi się na innym interfejsie albo gdy anchor nie jest dokładny. Po restarcie systemu anchor znika, więc monitor sprzątnie resolver i zamiar. Ponowne włączenie zawsze wymaga kliknięcia „Włącz”.
Opóźnienie reakcji: do ~5 s plus czas `pfctl`. W czasie uśpienia monitor nie działa; pierwszy cykl wykonuje się po wybudzeniu.

## Mullvad

Pomocnik nie wywołuje Mullvad. GUI tylko czyta `mullvad status` i `mullvad lockdown-mode get`, jako użytkownik, z CLI w pakiecie aplikacji. Brak `connect`/`disconnect`.

## Plik env Tailscale

Zarządza nim GUI jako użytkownik. Rozpoznawane są dokładnie dwie treści: prototypu i TailBridge. Inna treść lub symlink powoduje odmowę. Przy wyłączeniu plik jest przenoszony do `~/Library/Application Support/TailBridge/backups/`. Zmiana działa dopiero po restarcie Tailscale.
