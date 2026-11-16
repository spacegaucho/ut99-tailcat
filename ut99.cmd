@echo off
rem SPDX-FileCopyrightText: 2026 spacegaucho
rem SPDX-License-Identifier: GPL-3.0-or-later
rem ut99.cmd — shim so you can type "ut99 client tcp..." from cmd or PowerShell
rem without worrying about execution policies.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ut99.ps1" %*
