# helm-unittest-empty fixture

Ein gueltiges Chart mit `unittest: true`, aber **ohne** `tests/`-Verzeichnis.

Deckt Audit **G-4** ab. helm-unittest meldet dafuer:

    Test Suites: 0 passed, 0 total
    Tests:       0 passed, 0 total

und beendet sich mit **rc=0** (gemessen mit helm-unittest 1.1.2). Der Job war
damit gruen, geprueft wurde nichts — und `unittest: true` ist ein OPT-IN, mit
dem der Adopter erklaert, dass hier etwas zu pruefen ist.

Nicht zu verwechseln mit `helm-unittest-fail`: dort EXISTIEREN Tests und
schlagen fehl. Hier existiert keiner, und genau das soll auffallen.
