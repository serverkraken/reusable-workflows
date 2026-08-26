# gitops-bootstrap-only

GitOps-Repo, das die Erkennung erfuellt, aber **keine** Manifestpfade liefert.

`detect_gitops_kubernetes` verlangt `kubernetes/` + `.sops.yaml` +
(`makejinja.toml` | `bootstrap/templates/`). Die Pfadliste schliesst
`bootstrap`, `components` und `flux-system` aus — dieses Repo erfuellt also die
Erkennung und liefert trotzdem `manifests_paths: []`.

Vor dem Fix (Audit J-13) rendete das `manifests_paths: |-` ohne Inhalt:
gueltiges YAML mit leerem Wert, von actionlint unbeanstandet, aber der
kube-validate-Job scheiterte zur Laufzeit mit "nichts validiert … unter: ".

**Warum diese Fixture existiert:** die Divergenz zwischen Go- und Bash-Engine
war fuer das Paritaets-Gate unsichtbar, weil keine der 27 Fixtures ein
Bootstrap-only-Repo war. Genau dieselbe Blindheit wie bei L-4 und J-3.
