#!/usr/bin/env bats

# scripts/shellcheck-to-sarif.py wandelt `shellcheck -f json1` in SARIF 2.1.0,
# weil shellcheck selbst kein SARIF kann und der Katalog kein weiteres fremdes
# Binary einschleppen soll.

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../scripts/shellcheck-to-sarif.py"
  cd "$BATS_TEST_TMPDIR" || exit 1
}

@test "leere Fundliste ergibt gueltiges SARIF mit null Results" {
  echo '{"comments":[]}' > in.json
  run bash -c "python3 '$SCRIPT' --tool-version 0.10.0 < in.json"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.version == "2.1.0"'
  echo "$output" | jq -e '.runs | length == 1'
  echo "$output" | jq -e '.runs[0].results | length == 0'
  echo "$output" | jq -e '.runs[0].tool.driver.name == "ShellCheck"'
  echo "$output" | jq -e '.runs[0].tool.driver.version == "0.10.0"'
}

@test "ein Fund wird zu einem Result mit Regel-ID, Ort und Level" {
  cat > in.json <<'JSON'
{"comments":[{"file":"scripts/a.sh","line":3,"endLine":3,"column":5,"endColumn":9,
  "level":"warning","code":2086,"message":"Double quote to prevent globbing."}]}
JSON
  run bash -c "python3 '$SCRIPT' --tool-version 0.10.0 < in.json"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.runs[0].results[0].ruleId == "SC2086"'
  echo "$output" | jq -e '.runs[0].results[0].level == "warning"'
  echo "$output" | jq -e '.runs[0].results[0].locations[0].physicalLocation.artifactLocation.uri == "scripts/a.sh"'
  echo "$output" | jq -e '.runs[0].results[0].locations[0].physicalLocation.region.startLine == 3'
  echo "$output" | jq -e '.runs[0].results[0].locations[0].physicalLocation.region.startColumn == 5'
  echo "$output" | jq -e '.runs[0].tool.driver.rules[0].helpUri == "https://www.shellcheck.net/wiki/SC2086"'
}

# SARIF kennt error/warning/note. shellchecks `info` und `style` haben dort
# keine Entsprechung und muessen auf `note` fallen — sonst lehnt die
# CodeQL-Action den Upload ab.
@test "info und style werden auf note abgebildet" {
  cat > in.json <<'JSON'
{"comments":[
 {"file":"a.sh","line":1,"endLine":1,"column":1,"endColumn":2,"level":"info","code":2034,"message":"x"},
 {"file":"a.sh","line":2,"endLine":2,"column":1,"endColumn":2,"level":"style","code":2006,"message":"y"}]}
JSON
  run bash -c "python3 '$SCRIPT' --tool-version 0.10.0 < in.json"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '[.runs[0].results[].level] == ["note","note"]'
}

# Zwei Funde derselben Regel duerfen die Regel nur EINMAL deklarieren und
# beide muessen per ruleIndex darauf zeigen — sonst zaehlt der
# Code-Scanning-Tab dieselbe Regel doppelt.
@test "gleiche Regel wird nur einmal deklariert, ruleIndex zeigt darauf" {
  cat > in.json <<'JSON'
{"comments":[
 {"file":"a.sh","line":1,"endLine":1,"column":1,"endColumn":2,"level":"warning","code":2086,"message":"x"},
 {"file":"b.sh","line":9,"endLine":9,"column":1,"endColumn":2,"level":"warning","code":2086,"message":"y"}]}
JSON
  run bash -c "python3 '$SCRIPT' --tool-version 0.10.0 < in.json"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.runs[0].tool.driver.rules | length == 1'
  echo "$output" | jq -e '[.runs[0].results[].ruleIndex] == [0,0]'
}

# Ein Absturz von shellcheck liefert leere oder kaputte Ausgabe. Die darf NICHT
# als "null Funde" durchgehen — dieselbe Fehlerklasse wie in kube-lint.yml.
@test "kaputte Eingabe bricht ab statt leeres SARIF zu liefern" {
  echo 'not json' > in.json
  run bash -c "python3 '$SCRIPT' --tool-version 0.10.0 < in.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"kein gueltiges JSON"* ]]
}
