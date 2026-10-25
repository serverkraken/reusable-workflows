#!/usr/bin/env bash
# Fixture: erzeugt bewusst SC2086 (ungequotete Variable), damit der
# Failure-Path des Gates geprueft wird.
target=$1
cp $target /tmp/
