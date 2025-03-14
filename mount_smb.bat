@echo off
echo Mounting SMB share...
net use Z: \\localhost:4010 /persistent:yes
explorer.exe Z:
