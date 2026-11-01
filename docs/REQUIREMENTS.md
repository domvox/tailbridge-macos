# Wymagania projektowe

To cele projektu, nie lista zaliczonych testów ochrony. Rzeczywiste dowody i braki opisuje [ACCEPTANCE.txt](ACCEPTANCE.txt).

- Natywna aplikacja macOS: włącz, wyłącz, sprawdź, diagnostyka.
- Wyłączenie obejścia nie rozłącza Mullvad i nie osłabia jego ochrony.
- Żadnych zdalnych instalatorów, obcych skryptów, telemetrii ani odczytu sekretów.
- Proces uprzywilejowany nie wykonuje ani nie source-uje plików zapisywalnych przez zwykłego użytkownika.
- Reguły tylko dla aktualnego interfejsu i własnych adresów Tailscale; jawne `flags any no state`.
- Brak przeładowywania głównego PF i brak edycji `/etc/pf.conf`.
- Usuń nieaktualny wyjątek i własny resolver, gdy Tailscale przestanie działać lub interfejs zmieni tożsamość.
- Rozpoznane elementy prototypu adoptować ostrożnie; nie nadpisywać nieznanych plików.
- Cofanie ma zachowywać stan, propagować błędy i odmawiać usuwania zmienionych przez użytkownika plików.
- Osobne wyniki: IPv4, IPv6, zewnętrzny DNS, MagicDNS, ping systemowy, TCP, DERP/direct.
- Brak testu oznacza NOT VERIFIED, a nie brak wycieku.
- Testy błędnych danych, podmiany utun, częściowego rollbacku i awarii poleceń; testy nie dotykają prawdziwego `/etc`.
- Końcowy review głównego agenta po implementacji Opusa, przed wdrożeniem.
