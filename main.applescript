-- Ask for CubeCart install folder
set installFolder to choose folder with prompt "Select your CubeCart installation folder:"
set installPath to POSIX path of installFolder

-- Ask for prefix/domain (user may enter blank for none)
set prefixDialog to display dialog "Enter prefix/domain for extracted folders (e.g. example.com). Leave blank for none:" default answer ""
set prefixInput to text returned of prefixDialog

-- Build command to call the bundled script with 2 arguments
set scriptPath to POSIX path of (path to resource "prepare_comparison.sh")
set cmd to "chmod +x " & quoted form of scriptPath & " && " & quoted form of scriptPath & " " & quoted form of installPath & " " & quoted form of prefixInput

-- Run script & capture output
do shell script cmd
