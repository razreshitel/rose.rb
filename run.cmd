@echo off
REM Convenience wrapper - ruby.exe is not on PATH on this box.
REM Usage:  run.cmd --all -o rose
"C:\Ruby33-x64\bin\ruby.exe" "%~dp0rose.rb" %*
