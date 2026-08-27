#!/usr/bin/env bash
# Fixture: liegt bewusst in einem Unterordner (scripts/lib/), nicht direkt in
# scripts/. Erzeugt bewusst SC2086 (ungequotete Variable), wie bad.sh — der
# Zweck ist hier aber die VERSCHACHTELUNG: mit `paths: scripts/**/*.sh` haengt
# das Finden dieser Datei an git ls-files --glob-pathspecs im Collect-files-
# Schritt. Ohne das verlangt Gits Default-Pathspec fuer `**` einen
# dazwischenliegenden Ordner in genau der falschen Richtung, oder laesst die
# obersten Dateien aus — je nachdem, welcher der beiden ls-files-Aufrufe
# betroffen ist.
target=$1
cp $target /tmp/
