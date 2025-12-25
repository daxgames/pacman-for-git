#!/usr/bin/env bash

workdir=$(dirname "$0")

powershell -executionpolicy Bypass -f "${workdir}/update.ps1" $*
