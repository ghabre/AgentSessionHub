# fixclip.ps1
# Re-own the current Windows clipboard text from this (plain Win32) powershell
# process so the RDP client forwards it to the remote session.
#
# Why: Windows Terminal is a packaged Store app. This PC is the RDP *client*, and
# its clipboard channel intermittently fails to read a WT-owned clipboard -- the
# remote's Paste greys out ("copies once, then stops"). Re-setting the text from
# an ordinary Win32 owner fixes it. Text-only; leaves images/files alone.
Add-Type -AssemblyName System.Windows.Forms
$t = [System.Windows.Forms.Clipboard]::GetText()
if ($t) {
    [System.Windows.Forms.Clipboard]::Clear()
    [System.Windows.Forms.Clipboard]::SetText($t)
}
