# Convenience wrapper - ruby.exe is not on PATH on this box.
# Usage:  .\run.ps1 --all -o rose
#         .\run.ps1 --terminal --mode picotee --color-a white --color-b crimson
& "C:\Ruby33-x64\bin\ruby.exe" "$PSScriptRoot\rose.rb" @args
