@echo off
rem Re-own the current clipboard from a plain Win32 process (powershell.exe) so
rem RDP's clipboard agent (rdpclip) can read it.
rem
rem Why this is needed: Windows Terminal is a packaged Store app. When you select
rem text there (copyOnSelect), WT owns the clipboard, and rdpclip can't read a
rem packaged-app clipboard -- so the remote session's Paste button greys out.
rem Re-setting the text from powershell.exe makes a normal Win32 process the
rem owner, which rdpclip reads fine. This is the Notepad round-trip, automated.
rem
rem Usage: select text in the session (it copies), then run this, then paste in RDP.
powershell.exe -NoProfile -STA -Command "Add-Type -AssemblyName System.Windows.Forms; $t=[System.Windows.Forms.Clipboard]::GetText(); if($t){[System.Windows.Forms.Clipboard]::Clear(); [System.Windows.Forms.Clipboard]::SetText($t)}"
